import AppKit
import Combine
import SwiftUI

/// What Pip is doing; derived from ChatModel plus pointing.
enum PetState {
    case idle, listening, thinking, talking, pointing

    /// Talking follows the spoken line (estimated), not the silent on-screen text that streams after it.
    static func derive(listening: Bool, transcribing: Bool, busy: Bool, hasSpoken: Bool, speaking: Bool, pointing: Bool) -> PetState {
        if listening { return .listening }
        if transcribing { return .thinking }
        if speaking { return .talking }
        if busy, !hasSpoken { return .thinking }
        return pointing ? .pointing : .idle
    }
}

@MainActor
final class PetModel: ObservableObject {
    @Published var pointing = false
    @Published var layout = PetGeometry.Layout(origin: .zero, sprite: .zero, pointLeft: true, bubbleBelow: false)
    /// Set by `PetController.say`, with the reply that was latest then; a newer reply replaces it.
    @Published var said: (text: String, after: UUID?)?
    /// The answer the user closed (by clicking the bubble or hiding Glance).
    @Published var dismissed: UUID?
    /// Estimated end of the spoken line; nil when silent.
    @Published var talkUntil: Date?
}

/// Pip's own always-on-top window; shows chat state and points at things on screen.
@MainActor
final class PetController {
    var onTap: (() -> Void)?
    private let chat: ChatModel
    private let model = PetModel()
    private let window: NSPanel
    private let ring = RingWindow()
    static let size = NSSize(width: 300, height: 260)
    static let sprite = NSSize(width: 120, height: 90)
    private var home: PetGeometry.Layout?
    private var flight: Task<Void, Never>?
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    private var watchers: [AnyCancellable] = []
    private var spokenTurn: UUID?
    private var spokenStart = Date()
    private var talkTimer: Task<Void, Never>?

    init(chat: ChatModel) {
        self.chat = chat
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
        watchers = [
            chat.$answerRaw.sink { [weak self] in self?.spokenChanged($0) },
            chat.$listening.sink { [weak self] in if $0 { self?.stopTalking() } }, // barge-in stops speech
            chat.$muted.sink { [weak self] in if $0 { self?.stopTalking() } },
            NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
                .sink { [weak self] _ in self?.screensChanged() },
        ]
    }

    func show() {
        if home == nil { resetHome() }
        if let home { apply(home, animated: false) }
        window.orderFrontRegardless()
    }

    /// Fly next to `rect` (Cocoa screen coordinates, origin bottom-left) and point at it.
    /// `ring` draws Pip's own dashed box around it; the PointTool selection already has one.
    func point(at rect: CGRect, ring showRing: Bool = true) {
        model.pointing = true
        apply(PetGeometry.placement(for: rect, screens: NSScreen.screens.map(\.visibleFrame),
                                    window: Self.size, sprite: Self.sprite, gap: 8), animated: true)
        if showRing { ring.show(around: rect) } else { ring.hide() }
    }

    /// `rect` in AX/CG global coordinates (origin top-left of the primary screen).
    func point(atAX rect: CGRect, ring showRing: Bool = true) {
        point(at: PetGeometry.cocoaRect(fromAX: rect, primaryHeight: NSScreen.screens.first?.frame.height ?? 0), ring: showRing)
    }

    /// `rect` is a Vision normalized rect inside `region`, the captured area in Cocoa global points.
    func point(atVision rect: CGRect, in region: CGRect, ring showRing: Bool = true) {
        point(at: PetGeometry.cocoaRect(fromVision: rect, in: region), ring: showRing)
    }

    /// Show `text` in Pip's bubble until the user closes it or a newer answer arrives.
    func say(_ text: String) {
        model.said = (text, PetView.lastReply(in: chat.turns)?.id)
        model.dismissed = nil
    }

    /// Stop pointing, close the bubble and go back to the corner (used when Glance is hidden).
    func goHome() {
        model.pointing = false
        model.said = nil
        model.dismissed = PetView.lastReply(in: chat.turns)?.id
        ring.hide()
        if let home { apply(home, animated: true) }
    }

    /// Glance was shown: pop up in the centre of the active screen, then fly to its top-right corner.
    /// With Reduce Motion, appear at the corner directly.
    func appear() {
        let mouse = NSEvent.mouseLocation
        guard let vf = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame else { return }
        model.pointing = false
        ring.hide()
        let target = PetGeometry.home(in: vf, window: Self.size, sprite: Self.sprite)
        home = target
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            apply(target, animated: false)
            window.orderFrontRegardless()
            return
        }
        apply(PetGeometry.center(in: vf, window: Self.size, sprite: Self.sprite), animated: false)
        window.orderFrontRegardless()
        flight = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450)) // a beat in the middle so it's seen
            guard let self, !Task.isCancelled, self.home == target, !self.model.pointing else { return }
            self.apply(target, animated: true)
        }
    }

    private func resetHome() {
        guard let vf = NSScreen.main?.visibleFrame else { return }
        home = PetGeometry.home(in: vf, window: Self.size, sprite: Self.sprite)
    }

    private func screensChanged() {
        guard let h = home, PetGeometry.isOffScreen(h.spriteRect(Self.sprite), screens: NSScreen.screens.map(\.visibleFrame)) else { return }
        resetHome()
        if !model.pointing, let home { apply(home, animated: false) }
    }

    private func apply(_ l: PetGeometry.Layout, animated: Bool) {
        model.layout = l
        if animated { fly(to: l.origin) } else { flight?.cancel(); window.setFrameOrigin(l.origin) }
    }

    /// ponytail: talking time is estimated from the spoken line's length (Speaker doesn't publish playback);
    /// listening and mute cut it short, the Stop button doesn't.
    private func spokenChanged(_ answer: (turn: UUID, raw: String)?) {
        guard let answer, !chat.muted else { return }
        let line = PetView.spokenLine(answer.raw)
        guard !line.isEmpty else { return }
        if spokenTurn != answer.turn { spokenTurn = answer.turn; spokenStart = Date() }
        let until = spokenStart.addingTimeInterval(Self.speechSeconds(line))
        model.talkUntil = until
        talkTimer?.cancel()
        talkTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, until.timeIntervalSinceNow)))
            if !Task.isCancelled { self?.model.talkUntil = nil }
        }
    }

    private func stopTalking() {
        talkTimer?.cancel()
        model.talkUntil = nil
    }

    /// About 14 characters a second plus ~1 s before the first audio; Speaker speaks at most ~280 characters.
    nonisolated static func speechSeconds(_ line: String) -> Double { 1 + Double(min(line.count, 280)) / 14 }

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
        if dragStart != nil, !model.pointing {
            var l = model.layout
            l.origin = window.frame.origin
            home = l
        }
        dragStart = nil
    }

    private func drag() {
        let mouse = NSEvent.mouseLocation
        if dragStart == nil { flight?.cancel(); dragStart = (mouse, window.frame.origin) }
        guard let d = dragStart else { return }
        window.setFrameOrigin(NSPoint(x: d.origin.x + mouse.x - d.mouse.x, y: d.origin.y + mouse.y - d.mouse.y))
    }
}

struct PetView: View {
    @ObservedObject var chat: ChatModel
    @ObservedObject var model: PetModel
    let onTap: () -> Void
    let onDrag: () -> Void
    let onDragEnd: () -> Void

    nonisolated static func lastReply(in turns: [ChatModel.Turn]) -> ChatModel.Turn? {
        turns.last { $0.kind == .assistant || $0.kind == .notice }
    }

    /// The part of a raw answer that is read aloud: its "Say:" line, or the answer itself without one.
    nonisolated static func spokenLine(_ raw: String) -> String {
        switch Voice.splitSpoken(raw) {
        case .pending: return ""
        case .plain: return raw
        case .summary(let say, _, _): return say
        }
    }

    /// Bubble text: status while listening/thinking; otherwise `say()` text unless a newer reply came,
    /// then the reply's spoken line (the panel shows the full answer), unless the user closed it.
    nonisolated static func bubbleText(state: PetState, transcribing: Bool, said: (text: String, after: UUID?)?,
                                       reply: (id: UUID, text: String)?, spoken: String?, dismissed: UUID?) -> String? {
        switch state {
        case .listening: return "Listening…"
        case .thinking: return transcribing ? "Got it…" : "Thinking…"
        default:
            if let said, said.after == reply?.id { return said.text }
            guard let reply, reply.id != dismissed else { return nil }
            let text = spoken.flatMap { $0.isEmpty ? nil : $0 } ?? reply.text
            return text.isEmpty ? nil : text
        }
    }

    private var reply: ChatModel.Turn? { Self.lastReply(in: chat.turns) }

    private var spoken: String? {
        guard let a = chat.answerRaw, a.turn == reply?.id else { return nil }
        return Self.spokenLine(a.raw)
    }

    private var state: PetState {
        PetState.derive(listening: chat.listening, transcribing: chat.transcribing, busy: chat.busy,
                        hasSpoken: !(spoken ?? "").isEmpty, speaking: model.talkUntil.map { $0 > Date() } ?? false,
                        pointing: model.pointing)
    }

    var body: some View {
        let l = model.layout, w = PetController.size, s = PetController.sprite
        let spriteTop = w.height - l.sprite.y - s.height // SwiftUI y runs down
        let bubbleX = min(max(l.sprite.x + s.width / 2 - 130, 0), w.width - 260)
        let tailRight = l.sprite.x + s.width / 2 > bubbleX + 130
        ZStack(alignment: .topLeading) {
            if let bubble = Self.bubbleText(state: state, transcribing: chat.transcribing, said: model.said,
                                            reply: reply.map { ($0.id, $0.text) }, spoken: spoken, dismissed: model.dismissed) {
                PetBubbleView(text: bubble, tailOnRight: tailRight) { model.dismissed = reply?.id; model.said = nil }
                    .frame(width: 260, height: max(0, l.bubbleBelow ? w.height - spriteTop - s.height - 6 : spriteTop - 6),
                           alignment: Alignment(horizontal: tailRight ? .trailing : .leading, vertical: l.bubbleBelow ? .top : .bottom))
                    .offset(x: bubbleX, y: l.bubbleBelow ? spriteTop + s.height + 6 : 0)
            }
            PipSpriteView(state: state, pointLeft: l.pointLeft)
                .frame(width: s.width, height: s.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in if abs(v.translation.width) + abs(v.translation.height) > 3 { onDrag() } }
                    .onEnded { v in
                        if abs(v.translation.width) + abs(v.translation.height) <= 3 { onTap() }
                        onDragEnd()
                    })
                .help("Click to chat with Pip. Drag to move.")
                .offset(x: l.sprite.x, y: spriteTop)
        }
        .frame(width: w.width, height: w.height, alignment: .topLeading)
    }

    nonisolated static func selfTest(_ check: (Bool, String) -> Void) {
        // A13: an answer in progress wins over the pointing pose.
        check(PetState.derive(listening: false, transcribing: false, busy: true, hasSpoken: false, speaking: false, pointing: true) == .thinking,
              "pet A13: thinking shows while pointing")
        check(PetState.derive(listening: false, transcribing: true, busy: false, hasSpoken: false, speaking: false, pointing: true) == .thinking,
              "pet A13: transcribing shows while pointing")
        check(PetState.derive(listening: false, transcribing: false, busy: false, hasSpoken: true, speaking: false, pointing: true) == .pointing,
              "pet A13: back to pointing once done")
        // A14: talking follows speech, not the silent text after the Say line.
        check(PetState.derive(listening: false, transcribing: false, busy: true, hasSpoken: true, speaking: true, pointing: false) == .talking,
              "pet A14: talking while the spoken line plays")
        check(PetState.derive(listening: false, transcribing: false, busy: true, hasSpoken: true, speaking: false, pointing: false) == .idle,
              "pet A14: silent while the rest of the answer streams")
        check(PetState.derive(listening: false, transcribing: false, busy: false, hasSpoken: true, speaking: true, pointing: false) == .talking,
              "pet A14: still talking after streaming ends")
        check(spokenLine("Say: It's plenty.\nThe full answer…") == "It's plenty." && spokenLine("Plain answer here, long enough to tell.") != ""
              && spokenLine("Sa") == "", "pet A14: spoken line is the Say line, the plain answer, or nothing yet")
        check(PetController.speechSeconds("x") < PetController.speechSeconds(String(repeating: "x", count: 140))
              && PetController.speechSeconds(String(repeating: "x", count: 2000)) == PetController.speechSeconds(String(repeating: "x", count: 280)),
              "pet A14: speech estimate grows with length, capped at 280 characters")
        // Bubble text, A16 and say().
        let a = UUID(), b = UUID()
        func text(_ said: (text: String, after: UUID?)?, _ reply: (id: UUID, text: String)?, _ spoken: String?, _ dismissed: UUID?) -> String? {
            bubbleText(state: .idle, transcribing: false, said: said, reply: reply, spoken: spoken, dismissed: dismissed)
        }
        check(text(nil, (a, "Full answer"), "Short", nil) == "Short", "pet: bubble shows the spoken line, not the full answer")
        check(text(nil, (a, "Full answer"), nil, nil) == "Full answer", "pet: bubble falls back to the reply text")
        check(text(nil, (a, "Full answer"), "Short", a) == nil, "pet A16: a dismissed (hidden) answer stays hidden")
        check(text(nil, (b, "Newer"), nil, a) == "Newer", "pet A16: the next answer shows again")
        check(text(("Click Export", a), (a, "Old"), nil, nil) == "Click Export", "pet: say() text shows")
        check(text(("Click Export", a), (b, "New answer"), nil, nil) == "New answer", "pet: a newer answer replaces say() text")
        check(bubbleText(state: .listening, transcribing: false, said: ("x", nil), reply: nil, spoken: nil, dismissed: nil) == "Listening…",
              "pet: listening status wins")
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
