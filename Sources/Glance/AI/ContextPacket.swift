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
    var redactions: Int
    /// Guide's full-screen packet (Phase 5). Never sent unredacted, whatever the question says.
    var isScreen = false
    /// The recent-activity context from the on-device timeline (activity log + page text), already redacted.
    /// Always redacted, even when the user asks to reveal the selection. Empty unless a question was asked.
    var memory = ""
    var memoryPages = 0, memoryApps = 0, memoryHits = 0
    /// Newest timeline row in `memory`; follow-ups rebuild it when something newer was stored.
    var memoryNewest = 0.0
    /// Guide (local only, never sent): OCR lines with redacted text and pixel boxes (top-left, top to bottom),
    /// the captured area in Cocoa global points, and the shot's size in pixels.
    var lines: [OCR.Line] = []
    var region: CGRect = .zero
    var imageSize: CGSize = .zero
    /// Guide's user message; "{GOAL}" is replaced by the (redacted) question.
    var guideBlock: String?

    /// For a question asked without pointing at anything: memory only, no selection, no image.
    /// Redacted "what's on screen now" section for a question without a selection; `memory` starts with it, so the
    /// preview, the Send/Cancel check and the redaction count all cover it.
    private(set) var screenNow = ""
    private var screenNowHits = 0
    var hasSelection: Bool { !redacted.selectionImage.isEmpty }

    /// Adds (or replaces) the front window's text, redacted here. Text only; never an image.
    func withScreenNow(app: String, title: String?, text: String) -> ContextPacket {
        var copy = self
        let body = String(memory.dropFirst(screenNow.count))
        let t = Redactor.redact(String(text.prefix(Config.screenNowMaxChars)))
        let w = Redactor.redact(title ?? "")
        let head = "On screen now (\(app)" + (w.text.isEmpty ? "" : " — \"\(w.text)\"") + "):\n"
        copy.screenNow = head + t.text + "\n\n"
        copy.screenNowHits = t.hits + w.hits
        copy.memoryHits = memoryHits - screenNowHits + copy.screenNowHits
        copy.memory = copy.screenNow + body
        return copy
    }

    static func memoryOnly() -> ContextPacket {
        let empty = Content(selectionImage: Data(), selectedText: "")
        return ContextPacket(appName: "", redacted: empty, raw: empty, redactions: 0)
    }

    /// Adds (or replaces) the memory context, redacted here as one block before anything can reach `send()`.
    func withMemory(_ built: MemoryContext.Built) -> ContextPacket {
        var copy = self
        let r = Redactor.redact(built.text)
        copy.memory = screenNow + r.text
        copy.memoryHits = screenNowHits + r.hits
        copy.memoryPages = built.pages
        copy.memoryApps = built.apps
        copy.memoryNewest = built.newest
        return copy
    }

    /// What the user sees before anything goes out.
    struct Preview {
        let providerName: String
        /// The selection crop. Shown locally even when the provider gets text only.
        let image: NSImage?
        let imagesSent: Bool
        let selectedText: String
        let memory: String
        let memoryPages: Int
        let memoryApps: Int
        let redactions: Int
        let revealed: Bool
        /// High-risk tags going out (e.g. "[CARD]": 2), counted on the redacted text even when revealing.
        let highRisk: [String: Int]
        /// "Hid 2 card numbers and 1 IBAN. Send?" when a tap is needed (high-risk item or reveal), else nil.
        let confirmPrompt: String?
    }

    /// HARD RULE: this is the only code path that sends screen content off the Mac.
    /// `history` holds the user's own words and earlier answers. Everything the user wrote is redacted,
    /// and the redacted packet is attached to the first question, unless `reveal` is set because the user
    /// explicitly asked to see hidden data. `announce` shows the preview before the request starts.
    /// Phase 4: when `confirm` is given it is always awaited before anything goes out (Guide's consent); otherwise
    /// `SendConfirm` asks Send/Cancel only when the preview has a `confirmPrompt`. Cancel: nothing is sent and the
    /// stream ends without text.
    @MainActor
    static func send(_ packet: ContextPacket?, history: [ChatMessage], question: String, reveal: Bool, announce: Bool,
                     mode: Mode, provider: AIProvider, showPreview: (Preview) -> Void,
                     confirm: (@MainActor (Preview) async -> Bool)? = nil) -> AsyncThrowingStream<String, Error> {
        let reveal = reveal && !(packet?.isScreen ?? false)
        var questionHits = 0
        var redactedQuestion = question
        var turns = (history + [ChatMessage(role: .user, text: question)]).map { m -> ChatMessage in
            guard m.role == .user, !reveal else { return m }
            let r = Redactor.redact(m.text)
            questionHits = r.hits // the last user turn is the new question
            redactedQuestion = r.text
            return ChatMessage(role: .user, text: r.text)
        }
        if reveal { redactedQuestion = Redactor.redact(question).text }
        let content = packet.map { reveal ? $0.raw : $0.redacted }
        if let packet, let content, let first = turns.firstIndex(where: { $0.role == .user }) {
            turns[first] = packet.firstMessage(content, question: turns[first].text, imagesAllowed: provider.supportsImages)
        }
        // The packet's items count once per conversation (when announced); a new question's items count every time.
        let outgoing = announce ? [packet?.redacted.selectedText ?? "", packet?.memory ?? "", redactedQuestion] : [redactedQuestion]
        let highRisk = SendConfirm.highRisk(in: outgoing)
        let redactions = (reveal ? 0 : (packet?.redactions ?? 0) + questionHits) + (packet?.memoryHits ?? 0)
        let preview = Preview(providerName: provider.name, image: content.flatMap { NSImage(data: $0.selectionImage) },
                              imagesSent: provider.supportsImages && !(content?.selectionImage.isEmpty ?? true),
                              selectedText: content?.selectedText ?? "", memory: packet?.memory ?? "",
                              memoryPages: packet?.memoryPages ?? 0, memoryApps: packet?.memoryApps ?? 0,
                              redactions: redactions, revealed: reveal, highRisk: highRisk,
                              confirmPrompt: SendConfirm.prompt(highRisk: highRisk, total: redactions,
                                                                revealed: reveal && announce))
        if packet != nil && announce { showPreview(preview) }
        let ask = confirm ?? preview.confirmPrompt.map { prompt in { _ in await SendConfirm.shared.ask(prompt) } }
        guard let ask else { return provider.stream(system: mode.system, messages: turns) }
        let system = mode.system
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                guard await ask(preview), !Task.isCancelled else { continuation.finish(); return }
                do {
                    for try await delta in provider.stream(system: system, messages: turns) { continuation.yield(delta) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func firstMessage(_ content: Content, question: String, imagesAllowed: Bool) -> ChatMessage {
        if let guideBlock {
            return ChatMessage(role: .user, text: guideBlock.replacingOccurrences(of: "{GOAL}", with: question),
                               images: imagesAllowed && !content.selectionImage.isEmpty ? [content.selectionImage] : [])
        }
        let pointed = !content.selectionImage.isEmpty
        var text = pointed
            ? "App: \(appName)\nText in my selection (OCR):\n\(content.selectedText.isEmpty ? "(none)" : content.selectedText)\n"
            : "I didn't point at anything on screen.\n"
        if !screenNow.isEmpty {
            text += "\nWhat's on my screen right now (front window, OCR, redacted):\n\(screenNow)"
        }
        let body = memory.dropFirst(screenNow.count)
        if !body.isEmpty {
            text += "\nWhat I've been doing on this Mac in the last \(Config.retentionMinutes) min "
                + "(Glance's on-device memory, redacted):\n\(body)\n"
        }
        text += "\nMy question: \(question)"
        return ChatMessage(role: .user, text: text, images: imagesAllowed && pointed ? [content.selectionImage] : [])
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
            var selected: [String] = [], rawSelected: [String] = [], kept: [OCR.Line] = []
            let lines = try OCR.lines(in: shot, words: true)
            for (line, r) in zip(lines, Redactor.redactLines(lines.map(\.text))) {
                if r.hits > 0 { hits += r.hits; blackout.append(line.box.insetBy(dx: -4, dy: -4)) }
                selected.append(r.text)
                rawSelected.append(line.text)
                kept.append(OCR.Line(text: r.text, box: line.box, words: r.hits > 0 ? [] : line.words))
            }
            let redacted = try draw(shot, size: size) { ctx in
                ctx.setFillColor(.black)
                for box in blackout { ctx.fill(flip(box, height: size.height)) }
            }
            var packet = ContextPacket(
                appName: appName,
                redacted: Content(selectionImage: try jpeg(redacted), selectedText: selected.joined(separator: "\n")),
                raw: Content(selectionImage: try jpeg(shot), selectedText: rawSelected.joined(separator: "\n")),
                redactions: hits)
            packet.lines = kept.sorted { $0.box.minY < $1.box.minY }
            packet.region = selection
            packet.imageSize = size
            return packet
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
