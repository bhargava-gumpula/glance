import AppKit
import ScreenCaptureKit

/// What Glance knows about the thing you pointed at: only the selected region, never the rest of the screen.
/// Built already redacted: OCR lines with sensitive values are blacked out in the image and replaced in the text.
struct ContextPacket: Sendable {
    struct Content: Sendable {
        /// JPEG of the selection.
        let selectionImage: Data
        let selectedText: String
    }

    let appName: String
    /// What is normally sent.
    let redacted: Content
    /// Unredacted copy, kept in memory only. Sent only when the user explicitly asks Glance to look at hidden data.
    let raw: Content
    let redactions: Int

    /// What the user sees before anything goes out.
    struct Preview {
        let providerName: String
        /// The selection crop. Shown locally even when the provider gets text only.
        let image: NSImage?
        let imagesSent: Bool
        let selectedText: String
        let redactions: Int
        let revealed: Bool
    }

    /// HARD RULE: this is the only code path that sends screen content off the Mac.
    /// `history` holds the user's own words and earlier answers. Everything the user wrote is redacted,
    /// and the redacted packet is attached to the first question, unless `reveal` is set because the user
    /// explicitly asked to see hidden data. `announce` shows the preview before the request starts.
    @MainActor
    static func send(_ packet: ContextPacket?, history: [ChatMessage], question: String, reveal: Bool, announce: Bool,
                     mode: Mode, provider: AIProvider, showPreview: (Preview) -> Void) -> AsyncThrowingStream<String, Error> {
        var questionHits = 0
        var turns = (history + [ChatMessage(role: .user, text: question)]).map { m -> ChatMessage in
            guard m.role == .user, !reveal else { return m }
            let r = Redactor.redact(m.text)
            questionHits = r.hits // the last user turn is the new question
            return ChatMessage(role: .user, text: r.text)
        }
        if let packet, let first = turns.firstIndex(where: { $0.role == .user }) {
            let content = reveal ? packet.raw : packet.redacted
            turns[first] = packet.firstMessage(content, question: turns[first].text, imagesAllowed: provider.supportsImages)
            if announce {
                showPreview(Preview(providerName: provider.name, image: NSImage(data: content.selectionImage),
                                    imagesSent: provider.supportsImages, selectedText: content.selectedText,
                                    redactions: reveal ? 0 : packet.redactions + questionHits, revealed: reveal))
            }
        }
        return provider.stream(system: mode.system, messages: turns)
    }

    func firstMessage(_ content: Content, question: String, imagesAllowed: Bool) -> ChatMessage {
        let text = "App: \(appName)\nText in my selection (OCR):\n\(content.selectedText.isEmpty ? "(none)" : content.selectedText)\n"
            + "\nMy question: \(question)"
        return ChatMessage(role: .user, text: text, images: imagesAllowed ? [content.selectionImage] : [])
    }

    enum CaptureError: LocalizedError {
        case noDisplay, encode
        var errorDescription: String? {
            switch self {
            case .noDisplay: "Couldn't find that display to capture."
            case .encode: "Couldn't encode the screenshot."
            }
        }
    }

    /// Captures only the selected region (without Glance or excluded apps), OCRs it, and redacts it.
    /// `selection` is in AppKit global coordinates.
    @MainActor
    static func capture(selection: CGRect, on screen: NSScreen, appName: String) async throws -> ContextPacket {
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let screenFrame = screen.frame
        let scale = screen.backingScaleFactor

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw CaptureError.noDisplay }
        let hidden = content.applications.filter {
            $0.processID == getpid() || Config.excludedApps.contains($0.bundleIdentifier)
        }
        let filter = SCContentFilter(display: display, excludingApplications: hidden, exceptingWindows: [])
        // Capture just the selection, in display points with a top-left origin.
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: selection.minX - screenFrame.minX, y: screenFrame.maxY - selection.maxY,
                                   width: selection.width, height: selection.height)
        config.width = Int(selection.width * scale)
        config.height = Int(selection.height * scale)
        config.showsCursor = false
        let shot = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let size = CGSize(width: shot.width, height: shot.height)

        return try await Task.detached(priority: .userInitiated) {
            var hits = 0
            var blackout: [CGRect] = []
            var selected: [String] = [], rawSelected: [String] = []
            let lines = try OCR.lines(in: shot)
            for (line, r) in zip(lines, Redactor.redactLines(lines.map(\.text))) {
                if r.hits > 0 { hits += r.hits; blackout.append(line.box.insetBy(dx: -4, dy: -4)) }
                selected.append(r.text)
                rawSelected.append(line.text)
            }
            let redacted = try draw(shot, size: size) { ctx in
                ctx.setFillColor(.black)
                for box in blackout { ctx.fill(flip(box, height: size.height)) }
            }
            return ContextPacket(
                appName: appName,
                redacted: Content(selectionImage: try jpeg(redacted), selectedText: selected.joined(separator: "\n")),
                raw: Content(selectionImage: try jpeg(shot), selectedText: rawSelected.joined(separator: "\n")),
                redactions: hits)
        }.value
    }

    /// Top-left-origin rect to CGContext's bottom-left origin.
    private static func flip(_ r: CGRect, height: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
    }

    private static func draw(_ image: CGImage, size: CGSize, _ extra: (CGContext) -> Void) throws -> CGImage {
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureError.encode }
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        extra(ctx)
        guard let out = ctx.makeImage() else { throw CaptureError.encode }
        return out
    }

    /// Downscales to `Config.maxImageDimension` and encodes as JPEG.
    private static func jpeg(_ image: CGImage) throws -> Data {
        let longest = CGFloat(max(image.width, image.height))
        let s = min(1, CGFloat(Config.maxImageDimension) / longest)
        let size = CGSize(width: (CGFloat(image.width) * s).rounded(), height: (CGFloat(image.height) * s).rounded())
        let scaled = try draw(image, size: size) { _ in }
        guard let data = NSBitmapImageRep(cgImage: scaled)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { throw CaptureError.encode }
        return data
    }
}
