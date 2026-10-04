import AppKit
import ApplicationServices

/// Guide v1: "show me how to …" → one step at a time, Pip points at the real control. Glance never clicks.
enum Guide {
    // MARK: Pure helpers (selftested)

    static func isRequest(_ q: String) -> Bool {
        q.range(of: #"(?i)^\s*(show me how|how do i|how can i|walk me through|guide me|help me)\b"#, options: .regularExpression) != nil
    }

    enum Command: Equatable { case next, why, skip, stop }

    static func command(_ q: String) -> Command? {
        let t = q.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        switch t {
        case "next", "next step", "ok next", "done", "what next", "what's next": return .next
        case "why", "why?": return .why
        case "skip", "skip it", "skip this": return .skip
        case "stop", "cancel", "never mind", "nevermind", "stop guide": return .stop
        default: return nil
        }
    }

    /// Balanced top-level `{…}` objects that parse as JSON, in order. Braces inside strings don't count;
    /// a truncated object at the end is dropped.
    static func objects(in text: String) -> [String] {
        var out: [String] = []
        var depth = 0, inString = false, escaped = false
        var start: String.Index?
        for i in text.indices {
            let c = text[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"" where depth > 0: inString = true
            case "{":
                if depth == 0 { start = i }
                depth += 1
            case "}" where depth > 0:
                depth -= 1
                if depth == 0, let s = start {
                    let obj = String(text[s...i])
                    if jsonObject(obj) != nil { out.append(obj) }
                    start = nil
                }
            default: break
            }
        }
        return out
    }

    /// An id as soon as its closing quote has streamed in, so Pip can start moving early.
    static func earlyRef(in partial: String) -> String? {
        guard let r = partial.range(of: #""ref"\s*:\s*"([AMO]\d+)""#, options: .regularExpression) else { return nil }
        return partial[r].split(separator: "\"").last.map(String.init)
    }

    /// Phase 6's local advance: exactly one exact normalized label match, never "contains".
    static func localAdvance(_ label: String, candidates: [String]) -> Int? {
        let want = AX.normalizeTitle(label)
        let hits = candidates.indices.filter { AX.normalizeTitle(candidates[$0]) == want }
        return hits.count == 1 ? hits[0] : nil
    }

    /// OCR box (pixels, top-left, in an image of `size`) → Vision normalized rect (bottom-left), for `pet.point(atVision:in:)`.
    static func visionRect(ocrBox b: CGRect, imageSize size: CGSize) -> CGRect {
        CGRect(x: b.minX / size.width, y: 1 - b.maxY / size.height, width: b.width / size.width, height: b.height / size.height)
    }

    /// Cocoa global point → AX hit-test point. `h0` is `NSScreen.screens[0].frame.height`.
    static func axPoint(_ p: CGPoint, h0: CGFloat) -> CGPoint { CGPoint(x: p.x, y: h0 - p.y) }

    /// The OCR box for `label`: the whole line on an exact match, the union of its words inside a longer line.
    static func ocrBox(_ label: String, in lines: [OCR.Line]) -> CGRect? {
        let want = AX.normalizeTitle(label)
        guard !want.isEmpty else { return nil }
        if let l = lines.first(where: { AX.normalizeTitle($0.text) == want }) { return l.box }
        let tokens = want.split(separator: " ").map(String.init)
        for l in lines where l.words.count >= tokens.count {
            let words = l.words.map { AX.normalizeTitle($0.text) }
            for s in 0...(words.count - tokens.count) where Array(words[s..<s + tokens.count]) == tokens {
                return l.words[s..<s + tokens.count].map(\.box).reduce(CGRect.null) { $0.union($1) }
            }
        }
        return nil
    }

    static func describe(_ s: GuideStep) -> String {
        if let p = s.menu_path, !p.isEmpty { return p.joined(separator: " › ") }
        return s.label ?? s.say ?? "step"
    }

    // MARK: Front app

    /// The last app that wasn't Glance, so a Guide request typed into the panel targets the app behind it.
    @MainActor static var lastApp: NSRunningApplication?
    @MainActor private static var tracking: NSObjectProtocol?

    @MainActor static func startTracking() {
        guard tracking == nil else { return }
        if let a = NSWorkspace.shared.frontmostApplication, a.processIdentifier != getpid() { lastApp = a }
        tracking = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { if let app, app.processIdentifier != getpid() { lastApp = app } }
        }
    }

    @MainActor static func targetApp() -> NSRunningApplication? {
        let front = NSWorkspace.shared.frontmostApplication
        return front?.processIdentifier == getpid() ? lastApp : front
    }

    /// Why Guide won't look, or nil.
    @MainActor static func refusal(_ app: NSRunningApplication?) -> String? {
        guard let app else { return "I can't tell which app you're in. Click its window, then ask again." }
        if Exclusions.isExcluded(app) { return "Glance never looks at \(app.localizedName ?? "this app")." }
        if ActiveApp.secureInput() { return "A password field is active, so I won't look at the screen right now." }
        return nil
    }
}

/// The model's reply. Only `status` is required.
struct GuideStep: Decodable, Sendable {
    struct Next: Decodable, Sendable { let label: String?; let role: String?; let say: String? }
    let status: String
    var ref: String?
    var say: String?
    var label: String?
    var role: String?
    var menu_path: [String]?
    var why: String?
    var expect: String?
    var next: [Next]?
    var last: Bool?

    static func parse(_ raw: String) -> GuideStep? {
        guard let first = Guide.objects(in: raw).first else { return nil }
        return try? JSONDecoder().decode(GuideStep.self, from: Data(first.utf8))
    }

    /// Parse failure: a label recovered from any `"say"` text.
    static func recoveredSay(_ raw: String) -> String? {
        guard let r = raw.range(of: #""say"\s*:\s*"([^"]+)""#, options: .regularExpression) else { return nil }
        return raw[r].split(separator: "\"").last.map(String.init)
    }
}

extension ContextPacket {
    /// Adds Guide's menu, control and screen-text lists, every label redacted here. Ids: M#, then A#, then O#
    /// (OCR lines top to bottom), each the 1-based index into the list that stays on the Mac.
    func withGuide(progress: [String], windowTitle: String?, sheetTitle: String?, menus: [String], controls: [String]) -> ContextPacket {
        var copy = self
        var hits = 0
        func r(_ s: String) -> String { let x = Redactor.redact(s); hits += x.hits; return x.text }
        var t = "GOAL: {GOAL}\n"
        t += "PROGRESS: " + (progress.isEmpty ? "(none)" : progress.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: " | ")) + "\n"
        t += "APP: \(appName)"
        if let w = windowTitle { t += " — window \"\(r(w))\"" }
        if let s = sheetTitle { t += "; sheet: \"\(r(s))\"" }
        t += "\nMENUS:\n" + menus.enumerated().map { "M\($0 + 1) \(r($1))" }.joined(separator: "\n")
        t += "\nCONTROLS:\n" + controls.enumerated().map { "A\($0 + 1) \(r($1))" }.joined(separator: "\n")
        // Line text is already redacted by capture().
        t += "\nSCREEN TEXT (OCR, top to bottom):\n"
            + lines.prefix(Config.guideMaxOCRLines).enumerated().map { "O\($0 + 1) \"\($1.text)\"" }.joined(separator: "\n")
        copy.guideBlock = t
        copy.redactions += hits
        return copy
    }

    /// The whole screen under the mouse (without Glance or excluded apps), OCR'd with word boxes and redacted.
    @MainActor
    static func captureScreen(on screen: NSScreen, appName: String) async throws -> ContextPacket {
        try await capture(selection: screen.frame, on: screen, appName: appName)
    }
}

/// Where Pip points. All frames are converted only at `GuideHighlight`.
enum GuideTarget {
    case menuPath(MenuIndex.Entry, bar: AXUIElement?)
    case ax(CGRect)
    case ocr(CGRect, region: CGRect, imageSize: CGSize)
    case none
}

enum Locator {
    /// Never a guess: an unknown id falls back to an exact label search, else `.none`.
    @MainActor
    static func resolve(_ step: GuideStep, _ snap: AXSnapshot, _ packet: ContextPacket) -> GuideTarget {
        let screens = AX.screenFrames
        func menu(_ e: MenuIndex.Entry?) -> GuideTarget? {
            guard let e, let top = e.path.first else { return nil }
            return .menuPath(e, bar: snap.menus.barItem(top))
        }
        if let p = step.menu_path, !p.isEmpty, let t = menu(snap.menus.resolve(p)) { return t }
        if let ref = step.ref, let kind = ref.first, let n = Int(ref.dropFirst()), n >= 1 {
            switch kind {
            case "M" where n <= snap.menus.entries.count:
                if let t = menu(snap.menus.entries[n - 1]) { return t }
            case "A" where n <= snap.controls.count:
                let c = snap.controls[n - 1]
                // Read the frame live; if the element died, re-find it by label and role.
                if let f = AX.frame(of: c.element), AX.isUsable(f, screens: screens) { return .ax(f) }
                if let again = snap.controls.first(where: { $0.label == c.label && $0.role == c.role && !CFEqual($0.element, c.element) }),
                   let f = AX.frame(of: again.element) { return .ax(f) }
            case "O" where n <= packet.lines.count:
                let line = packet.lines[n - 1]
                let box = step.label.flatMap { Guide.ocrBox($0, in: [line]) } ?? line.box
                return .ocr(box, region: packet.region, imageSize: packet.imageSize)
            default: break
            }
        }
        guard let label = step.label ?? step.menu_path?.last else { return .none }
        let want = AX.normalizeTitle(label)
        let byLabel = snap.controls.filter { AX.normalizeTitle($0.label) == want }
            + snap.controls.filter { AX.normalizeTitle($0.label).hasPrefix(want) && AX.normalizeTitle($0.label) != want }
        if let c = byLabel.first, let f = AX.frame(of: c.element), AX.isUsable(f, screens: screens) { return .ax(f) }
        if let t = menu(snap.menus.resolve([label])) { return t }
        if let box = Guide.ocrBox(label, in: packet.lines) { return .ocr(box, region: packet.region, imageSize: packet.imageSize) }
        return .none
    }
}

/// The one place Guide touches Pip.
@MainActor
enum GuideHighlight {
    static weak var pet: PetController?
    /// Moves the chat panel off the target (`PanelController.avoid`).
    static var avoid: ((CGRect) -> Void)?

    static func show(_ cocoaRect: CGRect?, say: String?) {
        guard let pet else { return }
        if let r = cocoaRect {
            avoid?(r)
            pet.point(at: r)
        }
        if let say { pet.say(say) } else if cocoaRect == nil { pet.goHome() }
    }

    static func show(_ target: GuideTarget, say: String?) {
        let h0 = NSScreen.screens.first?.frame.height ?? 0
        switch target {
        case .menuPath(_, let bar):
            show(bar.flatMap(AX.frame).map { PetGeometry.cocoaRect(fromAX: $0, primaryHeight: h0) }, say: say)
        case .ax(let f): show(PetGeometry.cocoaRect(fromAX: f, primaryHeight: h0), say: say)
        case .ocr(let box, let region, let size):
            show(PetGeometry.cocoaRect(fromVision: Guide.visionRect(ocrBox: box, imageSize: size), in: region), say: say)
        case .none: show(nil, say: say)
        }
    }

    static func goHome() { pet?.goHome() }

    /// Pip may be hidden until ⌥Space; a Guide session brings it on screen first.
    static func begin() { pet?.show() }
}

/// Full-screen consent, through Phase 4's shared Send/Cancel step (the selftest swaps in a fake).
@MainActor
enum GuideConsent {
    /// Shows the card and waits; true = Send.
    static var ask: (String) async -> Bool = { await SendConfirm.shared.ask($0) }
}

/// One Guide conversation: a goal, the steps so far, and consent for this app.
@MainActor
final class GuideSession {
    private unowned let chat: ChatModel
    private(set) var goal: String?
    private var pid: pid_t = 0
    private var appName = ""
    private var progress: [String] = []
    private var step: GuideStep?
    private var stepNumber = 0
    private var snap = AXSnapshot()
    private var packet: ContextPacket?
    private var follower: MenuFollower?
    private var task: Task<Void, Never>?
    private var idle: Task<Void, Never>?
    private let speaker = Speaker()
    /// Consent holds for the same app and session, at most as many hidden items as approved, 20 sends, 10 min.
    private var consent: (pid: pid_t, redactions: Int, at: Date)?
    private var sends = 0

    init(chat: ChatModel) { self.chat = chat }

    var active: Bool { goal != nil }

    /// Called at the top of `ChatModel.ask`. True when Guide handled the words.
    func handle(_ q: String) -> Bool {
        if Guide.isRequest(q) || (chat.mode.name == Mode.guide.name && !active) { start(q); return true }
        guard active else { return false }
        switch Guide.command(q) {
        case .why: why()
        case .skip: skip()
        case .stop: stop(say: "Okay, stopping.")
        case .next, nil: next(userText: Guide.command(q) == nil ? q : nil)
        }
        return true
    }

    func start(_ q: String) {
        end()
        let app = Guide.targetApp()
        if let why = Guide.refusal(app) {
            chat.turns.append(.init(kind: .notice, text: why))
            GuideHighlight.show(nil, say: why)
            return
        }
        goal = q
        pid = app!.processIdentifier
        appName = app?.localizedName ?? "this app"
        progress = []
        stepNumber = 0
        sends = 0
        consent = nil
        chat.mode = .guide
        GuideHighlight.begin()
        GuideHighlight.show(nil, say: "Let me look at your screen…")
        runStep(userText: nil)
    }

    /// ⌥Space tap, spoken "next", or the Next button.
    func next(userText: String? = nil) {
        guard active else { return }
        if let s = step { progress.append(Guide.describe(s) + " → done") }
        runStep(userText: userText)
    }

    func why() {
        let text = step?.why ?? "I don't have a reason for this one."
        chat.turns.append(.init(kind: .assistant, text: text))
        speak(text)
        GuideHighlight.pet?.say(text)
    }

    func skip() {
        guard active else { return }
        if let s = step { progress.append("user skipped " + Guide.describe(s)) }
        runStep(userText: nil)
    }

    func stop(say: String? = nil) {
        guard active else { return }
        if let say { chat.turns.append(.init(kind: .notice, text: say)) }
        end()
        GuideHighlight.goHome()
    }

    private func end() {
        task?.cancel()
        idle?.cancel()
        follower?.stop()
        follower = nil
        speaker.stop()
        chat.busy = false
        goal = nil
        step = nil
        if chat.mode.name == Mode.guide.name { chat.mode = .explain }
    }

    private func runStep(userText: String?) {
        task?.cancel()
        follower?.stop()
        follower = nil
        speaker.stop()
        guard let goal else { return }
        chat.busy = true
        task = Task {
            defer { if !Task.isCancelled { chat.busy = false } }
            let app = NSRunningApplication(processIdentifier: pid)
            if let why = Guide.refusal(app) { stop(say: why); return }
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            guard let screen else { stop(say: "No screen to look at."); return }
            let started = Date()
            async let snapshot = AXSnapshot.take(pid: pid, screens: AX.screenFrames)
            let captured: ContextPacket
            do { captured = try await ContextPacket.captureScreen(on: screen, appName: appName) } catch {
                stop(say: "Couldn't read the screen: \(error.localizedDescription)")
                return
            }
            snap = await snapshot
            guard !Task.isCancelled else { return }
            log.notice("guide: snapshot \(self.snap.menus.entries.count, privacy: .public) menus, \(self.snap.controls.count, privacy: .public) controls, \(captured.lines.count, privacy: .public) lines in \(Date().timeIntervalSince(started), format: .fixed(precision: 2), privacy: .public) s")
            let packet = captured.withGuide(progress: progress, windowTitle: snap.windowTitle, sheetTitle: snap.sheetTitle,
                                            menus: snap.menus.entries.map(\.display), controls: snap.controls.map(\.display))
            self.packet = packet
            let provider: AIProvider
            do { provider = try Providers.current() } catch { stop(say: error.localizedDescription); return }

            let holds = consent.map { $0.pid == pid && packet.redactions <= $0.redactions && sends < Config.guideMaxSends
                && Date().timeIntervalSince($0.at) < Config.guideConsentMinutes * 60 } ?? false
            var question = goal
            if let userText { question += "\nUser says: \(userText)" }
            var refused = false
            let answer = GuideSend.send(packet, question: question, provider: provider, needsConsent: !holds,
                                        preview: { [weak self] text, image in
                                            self?.chat.turns.append(.init(kind: .preview, text: text, image: image))
                                        },
                                        consented: { [weak self] ok in
                                            guard let self else { return }
                                            if ok { self.consent = (self.pid, packet.redactions, Date()) } else { refused = true }
                                        })
            sends += 1
            var raw = ""
            var early: String?
            do {
                for try await delta in answer {
                    guard !Task.isCancelled else { return }
                    raw += delta
                    if early == nil, let ref = Guide.earlyRef(in: raw) {
                        early = ref
                        let t = Locator.resolve(GuideStep(status: "step", ref: ref), snap, packet)
                        if case .none = t {} else { GuideHighlight.show(t, say: nil) }
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                chat.turns.append(.init(kind: .notice, text: error.localizedDescription))
                GuideHighlight.show(nil, say: "I couldn't reach the model. Say next to try again.")
                return
            }
            guard !Task.isCancelled else { return }
            if refused { stop(say: "Nothing left your Mac."); return }
            show(raw)
        }
    }

    private func show(_ raw: String) {
        guard let s = GuideStep.parse(raw) else {
            // Parse failure: point by a recovered label, or just show the text.
            if let say = GuideStep.recoveredSay(raw) {
                let t = Locator.resolve(GuideStep(status: "step", say: say, label: say), snap, packet ?? .memoryOnly())
                chat.turns.append(.init(kind: .assistant, text: say))
                GuideHighlight.show(t, say: say)
                speak(say)
            } else {
                chat.turns.append(.init(kind: .assistant, text: raw.isEmpty ? "No answer." : raw))
            }
            return
        }
        step = s
        let say = s.say ?? s.label ?? ""
        switch s.status {
        case "done":
            chat.turns.append(.init(kind: .assistant, text: say.isEmpty ? "Done!" : say))
            speak(say.isEmpty ? "Done!" : say)
            GuideHighlight.show(nil, say: say.isEmpty ? "Done!" : say)
            finish()
        case "blocked", "not_found":
            chat.turns.append(.init(kind: .assistant, text: say))
            GuideHighlight.show(nil, say: say)
            speak(say)
        default:
            stepNumber += 1
            let target = Locator.resolve(s, snap, packet ?? .memoryOnly())
            var text = "**Step \(stepNumber):** \(Guide.describe(s))\n\(say)"
            if let why = s.why { text += "\n_Why:_ \(why)" }
            chat.turns.append(.init(kind: .assistant, text: text))
            if case .none = target { GuideHighlight.show(nil, say: say); speak(say); return }
            GuideHighlight.show(target, say: say)
            speak(say)
            if case .menuPath(let entry, let bar) = target { follow(entry.path, bar: bar, last: s.last ?? false) }
            resetIdle()
        }
    }

    /// Menu hops are followed locally; no model call until the user asks for the next step.
    private func follow(_ path: [String], bar: AXUIElement?, last: Bool) {
        let f = MenuFollower(pid: pid, path: path, barItem: bar) { [weak self] event in
            guard let self else { return }
            let h0 = NSScreen.screens.first?.frame.height ?? 0
            self.resetIdle()
            switch event {
            case .point(let frame, let say):
                GuideHighlight.show(PetGeometry.cocoaRect(fromAX: frame, primaryHeight: h0), say: say)
                self.speak(say)
            case .redirect(let frame, let say):
                GuideHighlight.show(frame.map { PetGeometry.cocoaRect(fromAX: $0, primaryHeight: h0) }, say: say)
                self.speak(say)
            case .done:
                self.follower?.stop()
                self.follower = nil
                if last {
                    self.progress.append(path.joined(separator: " › ") + " → done")
                    self.speak("Done!")
                    GuideHighlight.show(nil, say: "Done!")
                    self.finish()
                } else {
                    let say = "Nice. Say next, or tap \(Config.hotkeyDescription), for the next step."
                    GuideHighlight.show(nil, say: say)
                    self.speak("Nice. Say next for the next step.")
                }
            }
        }
        f.start()
        follower = f
    }

    private func finish() {
        let mine = goal
        idle?.cancel()
        follower?.stop()
        follower = nil
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.goal == mine else { return }
            self.end()
            GuideHighlight.goHome()
        }
    }

    /// After 90 s without progress Pip goes home; the session can still be resumed with "next".
    private func resetIdle() {
        idle?.cancel()
        idle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(90))
            guard !Task.isCancelled else { return }
            GuideHighlight.goHome()
            self?.follower?.stop()
            self?.follower = nil
        }
    }

    private func speak(_ text: String) {
        guard !text.isEmpty else { return }
        speaker.begin(Voice.tts(muted: chat.muted) { _ in })
        speaker.feed(text)
        speaker.finish()
    }
}

/// Guide's single path to the model: `ContextPacket.send`, with consent before the first full-screen send.
@MainActor
enum GuideSend {
    static func send(_ packet: ContextPacket, question: String, provider: AIProvider, needsConsent: Bool,
                     preview: @escaping (String, NSImage?) -> Void,
                     consented: @escaping (Bool) -> Void) -> AsyncThrowingStream<String, Error> {
        var packet = packet
        packet.isScreen = true // send() then never reveals unredacted text
        let names = packet.guideBlock.map { $0.split(separator: "\n").filter { $0.first == "M" || $0.first == "A" }.count } ?? 0
        let what = provider.supportsImages ? "image + \(packet.lines.count) lines + \(names) control names"
            : "text only (\(packet.lines.count) lines + \(names) control names); the image stays on this Mac"
        let card = "Guide will send your whole screen (redacted) to \(provider.name): \(what). Hid \(packet.redactions)."
        @MainActor func ask(_ p: ContextPacket.Preview) async -> Bool {
            let ok = await GuideConsent.ask(card + (p.confirmPrompt.map { " " + $0 } ?? " Send?"))
            consented(ok)
            return ok
        }
        // Every send still adds a non-blocking preview row.
        return ContextPacket.send(packet, history: [], question: question, reveal: false, announce: true,
                                  mode: .guide, provider: provider, showPreview: { p in preview(card, p.image) },
                                  confirm: needsConsent ? ask : nil)
    }
}
