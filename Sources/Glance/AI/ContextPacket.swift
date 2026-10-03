import AppKit
import ScreenCaptureKit

/// What Glance knows about the thing you pointed at. Built already redacted:
/// OCR lines with sensitive values are blacked out in the images and replaced in the text.
struct ContextPacket: Sendable {
    let appName: String
    /// JPEG crop of the selection.
    let selectionImage: Data
    /// JPEG of the whole screen, downscaled, with the selection outlined in red.
    let screenImage: Data
    let selectedText: String
    let screenText: String
    let redactions: Int

    /// What the user sees before anything goes out.
    struct Preview {
        let providerName: String
        /// The selection crop. Shown locally even when the provider gets text only.
        let image: NSImage?
        let imagesSent: Bool
        let selectedText: String
        let redactions: Int
    }

    /// HARD RULE: this is the only code path that sends screen content off the Mac.
    /// It redacts the question too, and shows the preview before the request starts.
    @MainActor
    static func send(_ packet: ContextPacket?, question: String, history: [ChatMessage], mode: Mode,
                     provider: AIProvider, showPreview: (Preview) -> Void)
        -> (message: ChatMessage, answer: AsyncThrowingStream<String, Error>) {
        let q = Redactor.redact(question)
        var message = ChatMessage(role: .user, text: q.text)
        if let packet, history.isEmpty {
            message = packet.firstMessage(question: q.text, imagesAllowed: provider.supportsImages)
            showPreview(Preview(providerName: provider.name, image: NSImage(data: packet.selectionImage),
                                imagesSent: provider.supportsImages, selectedText: packet.selectedText,
                                redactions: packet.redactions + q.hits))
        }
        return (message, provider.stream(system: mode.system, messages: history + [message]))
    }

    func firstMessage(question: String, imagesAllowed: Bool) -> ChatMessage {
        var text = "App: \(appName)\nText in my selection (OCR):\n\(selectedText.isEmpty ? "(none)" : selectedText)\n"
        if !imagesAllowed { text += "\nOther text on screen (OCR):\n\(screenText)\n" }
        text += "\nMy question: \(question)"
        return ChatMessage(role: .user, text: text, images: imagesAllowed ? [selectionImage, screenImage] : [])
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

    /// Captures the screen (without Glance or excluded apps), OCRs it, and redacts it.
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
        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.showsCursor = false
        let shot = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        let px = CGFloat(shot.width) / screenFrame.width
        let full = CGRect(x: 0, y: 0, width: shot.width, height: shot.height)
        let crop = CGRect(x: (selection.minX - screenFrame.minX) * px, y: (screenFrame.maxY - selection.maxY) * px,
                          width: selection.width * px, height: selection.height * px).integral.intersection(full)

        return try await Task.detached(priority: .userInitiated) {
            let lines = try OCR.lines(in: shot)
            var hits = 0
            var blackout: [CGRect] = []
            var selected: [String] = []
            var all: [String] = []
            for line in lines {
                let r = Redactor.redact(line.text)
                if r.hits > 0 { hits += r.hits; blackout.append(line.box.insetBy(dx: -4, dy: -4)) }
                all.append(r.text)
                if crop.contains(CGPoint(x: line.box.midX, y: line.box.midY)) { selected.append(r.text) }
            }
            let redacted = try draw(shot, size: full.size) { ctx in
                ctx.setFillColor(.black)
                for box in blackout { ctx.fill(flip(box, height: full.height)) }
            }
            guard let cropped = redacted.cropping(to: crop) else { throw CaptureError.encode }
            let outlined = try draw(redacted, size: full.size) { ctx in
                ctx.setStrokeColor(CGColor(red: 1, green: 0.1, blue: 0.1, alpha: 1))
                ctx.setLineWidth(max(4, px * 3))
                ctx.stroke(flip(crop, height: full.height))
            }
            return ContextPacket(appName: appName, selectionImage: try jpeg(cropped), screenImage: try jpeg(outlined),
                                 selectedText: selected.joined(separator: "\n"),
                                 screenText: all.joined(separator: "\n"), redactions: hits)
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
