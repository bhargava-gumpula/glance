import AppKit
import SwiftUI

/// What Pip is doing; derived from ChatModel plus pointing.
enum PetState { case idle, listening, thinking, talking, pointing }

@MainActor
final class PetModel: ObservableObject {
    @Published var pointing = false
    @Published var pointLeft = true
    /// Set by `PetController.say`; shown instead of the chat's last answer.
    @Published var said: String?
    /// The answer the user closed by clicking the bubble.
    @Published var dismissed: UUID?
}

/// Pip's own always-on-top window; shows chat state and points at things on screen.
@MainActor
final class PetController {
    var onTap: (() -> Void)?
    private let model = PetModel()
    private let window: NSPanel
    private let ring = RingWindow()
    private static let size = NSSize(width: 300, height: 260)
    static let sprite = NSSize(width: 120, height: 90)
    private var home: NSPoint?
    private var flight: Task<Void, Never>?
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    init(chat: ChatModel) {
        window = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = .floating
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: PetView(
            chat: chat, model: model,
            onTap: { [weak self] in self?.onTap?() },
            onDrag: { [weak self] in self?.drag() },
            onDragEnd: { [weak self] in self?.dragEnded() }))
    }

    func show() {
        if home == nil, let vf = NSScreen.main?.visibleFrame {
            home = NSPoint(x: vf.maxX - Self.size.width - 16, y: vf.minY + 16)
        }
        if let home { window.setFrameOrigin(home) }
        window.orderFrontRegardless()
    }

    /// Fly next to `rect` (Cocoa screen coordinates, origin bottom-left) and point at it.
    /// `ring` draws Pip's own dashed box around it; the PointTool selection already has one.
    func point(at rect: CGRect, ring showRing: Bool = true) {
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        let s = Self.sprite, w = Self.size
        let left = rect.maxX + 8 + s.width <= vf.maxX // room on the right: sit there, point left
        model.pointLeft = left
        model.pointing = true
        var x = left ? rect.maxX + 8 + s.width - w.width : rect.minX - 8 - s.width
        var y = rect.midY - s.height / 2
        x = min(max(x, vf.minX), vf.maxX - w.width)
        y = min(max(y, vf.minY), vf.maxY - w.height)
        fly(to: NSPoint(x: x, y: y))
        if showRing { ring.show(around: rect) } else { ring.hide() }
    }

    /// Show `text` in Pip's bubble (until the next `home()` or new answer is dismissed).
    func say(_ text: String) {
        model.said = text
        model.dismissed = nil
    }

    /// Stop pointing and go back to the corner.
    func goHome() {
        model.pointing = false
        model.said = nil
        ring.hide()
        if let home { fly(to: home) }
    }

    /// Stepped glide, like a sprite moving on a grid.
    private func fly(to target: NSPoint) {
        flight?.cancel()
        let start = window.frame.origin
        flight = Task { [window] in
            for i in 1...8 {
                try? await Task.sleep(for: .milliseconds(60))
                if Task.isCancelled { return }
                let f = CGFloat(i) / 8
                window.setFrameOrigin(NSPoint(x: start.x + (target.x - start.x) * f, y: start.y + (target.y - start.y) * f))
            }
        }
    }

    private func dragEnded() {
        if dragStart != nil, !model.pointing { home = window.frame.origin }
        dragStart = nil
    }

    private func drag() {
        let mouse = NSEvent.mouseLocation
        if dragStart == nil { flight?.cancel(); dragStart = (mouse, window.frame.origin) }
        guard let d = dragStart else { return }
        window.setFrameOrigin(NSPoint(x: d.origin.x + mouse.x - d.mouse.x, y: d.origin.y + mouse.y - d.mouse.y))
    }
}

private struct PetView: View {
    @ObservedObject var chat: ChatModel
    @ObservedObject var model: PetModel
    let onTap: () -> Void
    let onDrag: () -> Void
    let onDragEnd: () -> Void

    private var state: PetState {
        if chat.listening { return .listening }
        if model.pointing { return .pointing }
        if chat.transcribing { return .thinking }
        if chat.busy { return chat.turns.last?.kind == .assistant && chat.turns.last?.text.isEmpty == false ? .talking : .thinking }
        return .idle
    }

    private var lastReply: ChatModel.Turn? {
        chat.turns.last { $0.kind == .assistant || $0.kind == .notice }
    }

    private var bubble: String? {
        switch state {
        case .listening: return "Listening…"
        case .thinking: return chat.transcribing ? "Got it…" : "Thinking…"
        default:
            if let said = model.said { return said }
            guard let reply = lastReply, reply.id != model.dismissed, !reply.text.isEmpty else { return nil }
            return reply.text
        }
    }

    var body: some View {
        VStack(alignment: model.pointLeft ? .trailing : .leading, spacing: 6) {
            Spacer(minLength: 0)
            if let bubble {
                PetBubbleView(text: bubble) { model.dismissed = lastReply?.id; model.said = nil }
            }
            PipSpriteView(state: state, pointLeft: model.pointLeft)
            .frame(width: PetController.sprite.width, height: PetController.sprite.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in if abs(v.translation.width) + abs(v.translation.height) > 3 { onDrag() } }
                .onEnded { v in
                    if abs(v.translation.width) + abs(v.translation.height) <= 3 { onTap() }
                    onDragEnd()
                })
            .help("Click to chat with Pip. Drag to move.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.pointLeft ? .bottomTrailing : .bottomLeading)
    }
}

/// Click-through dashed box Pip draws around what it points at.
@MainActor
private final class RingWindow {
    private var window: NSWindow?

    func show(around rect: CGRect) {
        hide()
        let frame = rect.insetBy(dx: -6, dy: -6)
        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: Rectangle()
            .strokeBorder(PipSprite.accent, style: StrokeStyle(lineWidth: 3, dash: [8, 5])))
        w.orderFrontRegardless()
        window = w
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }
}
