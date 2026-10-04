import AppKit
import Combine
import SwiftUI

/// Floating panel that sits above every app without stealing focus from it.
@MainActor
final class PanelController {
    private let panel: NSPanel
    private let chat = ChatModel()
    private let pointTool = PointTool()
    let pet: PetController
    /// Pip-only by default: the panel shows only after Show more or the menu's Show Glance.
    private(set) var surface = GlanceSurface()
    private var watchers: [AnyCancellable] = []
    /// Phase 3 memory, searched only when the user asks.
    var timeline: Timeline? {
        get { chat.timeline }
        set { chat.timeline = newValue }
    }

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
            styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView],
            backing: .buffered, defer: true
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: PanelView(chat: chat))
        pet = PetController(chat: chat) // Phase 8: hidden until ⌥Space (appear())

        chat.onPoint = { [weak self] in self?.pointTool.start() }
        pointTool.onSelect = { [weak self] rect, screen in
            guard let self else { return }
            self.chat.pointed(at: rect, on: screen)
            self.pet.point(at: rect, ring: false)
            self.focusTyping()
        }
        pointTool.onCancel = { [weak self] in self?.focusTyping() }
        pet.onTap = { [weak self] in self?.petTapped() }
        pet.onShowMore = { [weak self] in self?.showMore() }
        pet.onQuiet = { [weak self] in self?.answerMaybeDone() }
        chat.onShowMore = { [weak self] in self?.showMore() }
        chat.onClearHighlight = { [weak self] in self?.clearSelectionHighlight() }
        watchers = [chat.$busy.sink { [weak self] _ in DispatchQueue.main.async { self?.answerMaybeDone() } }]
        GuideHighlight.pet = pet
        // Integration: Pip stays on screen during a Guide session or while a Send/Cancel question is pending.
        pet.keepVisible = { [weak chat = self.chat] in (chat?.guide.active ?? false) || SendConfirm.shared.prompt != nil }
        GuideHighlight.avoid = { [weak self] in self?.avoid($0) }
        Guide.startTracking()
    }

    /// Guide: move the chat to the other side of the screen when it covers what Pip points at.
    func avoid(_ rect: CGRect) {
        guard panel.isVisible, panel.frame.intersects(rect),
              let vf = (NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main)?.visibleFrame else { return }
        let x = rect.midX > vf.midX ? vf.minX + 16 : vf.maxX - panel.frame.width - 16
        panel.setFrameOrigin(NSPoint(x: x, y: panel.frame.minY))
    }

    /// Clicking Pip opens its one-line field (or hides Glance when it's open).
    private func petTapped() {
        if surface.pipTapped() { showPip(focus: true) } else { hide() }
    }

    private func hide() {
        surface.hide()
        panel.orderOut(nil)
        clearSelectionHighlight()
        pet.hideCompact()
        pet.goHome()
        pet.disappear()
    }

    /// Pip's bubble "Show more" (or the panel's ✕): the full chat with the complete answer and history. Pip stays.
    func showMore() {
        surface.showMore()
        if surface.panel { showPanel(); pet.hideCompact() } else { panel.orderOut(nil); if surface.compact { pet.showCompact(focus: false) } }
    }

    private func showPip(focus: Bool) {
        pet.appear()
        if surface.compact { pet.showCompact(focus: focus) }
    }

    /// Where typing goes now: the panel's field when it's open, else Pip's one-line field.
    private func focusTyping() {
        if surface.panel { focusInput() } else { surface.compact = true; surface.pip = true; pet.showCompact(focus: true) }
    }

    /// The drag-box highlight lasts until its answer is done (streamed and spoken). Guide's ring is its own.
    private func answerMaybeDone() {
        if ChatModel.clearsHighlight(.answerSettled(busy: chat.busy, speaking: pet.isSpeaking),
                                     guideActive: chat.guide.active, asked: chat.askedSinceSelection) {
            clearSelectionHighlight()
        }
    }

    private func clearSelectionHighlight() {
        guard !chat.guide.active else { return }
        pointTool.clear()
        pet.stopPointing()
    }

    var isVisible: Bool { surface.pip || surface.panel }

    func showStatus(_ text: String) { chat.status = text }

    /// Phase 8: shows memory paused / not saving / off as a chip in the panel.
    func showMemory(_ state: MemoryRecorder.State) { chat.memoryState = state }

    /// Key-event times (seconds since boot, from the events themselves), so a slow mic start can't turn a tap into a hold.
    private var pressedAt: TimeInterval?
    private var holdTimer: Task<Void, Never>?

    /// ⌥Space down: start recording right away (so the first word isn't clipped); it counts as talking once held.
    func keyDown(at time: TimeInterval) {
        guard pressedAt == nil else { return } // key repeat
        pressedAt = time
        holdTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Config.holdToTalkSeconds))
            guard let self, !Task.isCancelled else { return }
            if !self.isVisible { self.surface.hold(); self.pet.appear() }
            self.chat.listening = true
        }
        chat.startRecording()
    }

    /// ⌥Space up: a quick tap toggles the panel as before; after a hold, the recording becomes the question.
    func keyUp(at time: TimeInterval) {
        guard let pressed = pressedAt else { return }
        pressedAt = nil
        holdTimer?.cancel()
        if Self.isTap(pressed: pressed, released: time) {
            chat.discardRecording()
            switch surface.tap(guideActive: chat.guide.active) {
            case .guideNext: chat.guide.next() // during a Guide session a tap means "next"
            case .hide: hide()
            case .showToType: showPip(focus: true) // Pip + its one-line field; no panel, no pointing overlay
            }
        } else {
            // The release can beat the hold timer; the question needs the panel either way.
            if !isVisible { surface.hold(); pet.appear() }
            chat.askFromRecording()
        }
    }

    nonisolated static func isTap(pressed: TimeInterval, released: TimeInterval) -> Bool {
        released - pressed < Config.holdToTalkSeconds
    }

    /// Menu "Show Glance": the full panel (or hide everything).
    func toggle() {
        if surface.menuShow() { pet.appear(); showPanel(); focusInput() } else { hide() }
    }

    private func showPanel() {
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            // Left of Pip's top-right home, so Pip and its bubble don't cover the chat.
            panel.setFrameOrigin(NSPoint(x: frame.maxX - PetController.size.width - 8 - panel.frame.width,
                                         y: frame.maxY - panel.frame.height - 24))
        }
        panel.orderFrontRegardless()
    }

    private func focusInput() {
        panel.makeKeyAndOrderFront(nil)
        if let field = firstTextField(in: panel.contentView) { panel.makeFirstResponder(field) }
    }

    private func firstTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        for sub in view.subviews { if let f = firstTextField(in: sub) { return f } }
        return nil
    }
}

@MainActor
final class ChatModel: ObservableObject {
    struct Turn: Identifiable {
        enum Kind { case user, assistant, preview, notice }
        let id = UUID()
        let kind: Kind
        var text: String
        var image: NSImage? = nil
    }

    @Published var turns: [Turn] = []
    @Published var input = ""
    @Published var busy = false
    @Published var status = "Ask about what's on screen, or click Point to select part of it."
    /// Display only (Phase 8 memory chip).
    @Published var memoryState: MemoryRecorder.State = .recording
    /// Hold-to-talk: true while ⌥Space is held, `transcribing` until the text is back.
    @Published var listening = false {
        didSet {
            guard listening else { return }
            speaker.stop() // barge-in only once the press counts as a hold, not on a tap
            if Keychain.has(Voice.elevenLabsAccount) { Voice.prewarmElevenLabs() }
        }
    }
    @Published var transcribing = false
    /// The answer being streamed, unsplit, so Pip can show and time its spoken line.
    @Published var answerRaw: (turn: UUID, raw: String)?
    @Published var muted = !Config.ttsEnabled {
        didSet {
            UserDefaults.standard.set(!muted, forKey: "ttsEnabled")
            if muted { speaker.stop() }
        }
    }
    var onPoint: (() -> Void)?
    var onShowMore: (() -> Void)?
    /// Clears the drag-box highlight (PointTool overlay and Pip's pointing pose).
    var onClearHighlight: (() -> Void)?
    /// A question was asked about the current selection; its highlight goes once that answer is done.
    private(set) var askedSinceSelection = false
    /// The last question failed (error card in the panel); Pip's bubble offers Show more.
    @Published var failed = false
    var timeline: Timeline?

    enum HighlightEvent { case answerSettled(busy: Bool, speaking: Bool), newQuestion, hide, stop }

    /// When the drag-box highlight goes: its answer finished streaming and speaking, a new question, hide or Stop.
    nonisolated static func clearsHighlight(_ e: HighlightEvent, guideActive: Bool, asked: Bool) -> Bool {
        guard !guideActive else { return false } // Guide controls its own ring
        switch e {
        case .answerSettled(let busy, let speaking): return asked && !busy && !speaking
        case .newQuestion: return asked
        case .hide, .stop: return true
        }
    }

    @Published var mode = Mode.explain
    lazy var guide = GuideSession(chat: self)
    private var capture: Task<ContextPacket?, Never>?
    /// The user's own words and the answers; ContextPacket.send() redacts and attaches the selection.
    private var history: [ChatMessage] = []
    /// Set once the user explicitly asks to see hidden data; lasts until the next selection.
    private var revealed = false
    /// Provider name and image setting from the last "Sending to …" preview of this conversation (audit A2).
    private var previewedFor: (String, Bool)?
    private var answering: Task<Void, Never>?
    private let recorder = Recorder()
    private let speaker = Speaker()
    private var recordingOK = false

    /// Bumped by every new recording, question and selection; a transcription that finishes after one of
    /// those is stale and dropped (the newer action replaces it).
    private var serial = 0
    private var transcriptions = 0

    func startRecording() {
        serial += 1
        do { try recorder.start(); recordingOK = true } catch { recordingOK = false }
    }

    /// Voice problems are shown once each per launch, so a broken voice doesn't repeat under every answer.
    private var voiceNotices: Set<String> = []
    private func voiceNotice(_ text: String, detail: String? = nil) {
        guard voiceNotices.insert(text).inserted else { return }
        turns.append(Turn(kind: .notice, text: detail.map { "\(text) (\($0))" } ?? text))
    }
    nonisolated static let macVoiceNotice = "Using Mac voice."

    func discardRecording() {
        _ = recorder.stop()
        listening = false
    }

    func askFromRecording() {
        listening = false
        guard recordingOK else {
            turns.append(Turn(kind: .notice, text: VoiceError.noMicrophone.localizedDescription))
            return
        }
        transcribing = true
        let mine = serial
        transcriptions += 1
        let ticket = transcriptions
        let released = Date()
        Task {
            defer { if transcriptions == ticket { transcribing = false } } // a newer one owns the indicator
            try? await Task.sleep(for: .milliseconds(150)) // keep the tail of the last word
            guard serial == mine else { return } // a new press took the mic; it replaces this question
            let wav = recorder.stop()
            guard Recorder.duration(ofWAV: wav) >= 0.3 else {
                turns.append(Turn(kind: .notice, text: VoiceError.nothingHeard.localizedDescription))
                return
            }
            do {
                let heard = try await Voice.transcribe(wav: wav, with: Voice.sttChain())
                guard serial == mine else { return } // the user moved on (new question, selection or recording)
                // Phase 4: a spoken "send" / "cancel" answers a waiting Send/Cancel instead of asking a new question.
                if SendConfirm.shared.prompt != nil, let send = SendConfirm.spokenAnswer(heard.text) {
                    transcribing = false
                    SendConfirm.shared.answer(send)
                    return
                }
                log.notice("voice: transcribed by \(heard.engine, privacy: .public) in \(Date().timeIntervalSince(released), format: .fixed(precision: 2), privacy: .public) s")
                let shown = heard.engine == "ElevenLabs" ? "🎙 \(heard.text)" : "🎙 \(heard.text) (\(heard.engine))"
                transcribing = false
                ask(heard.text, shown: shown, spokenAt: released)
            } catch {
                guard serial == mine else { return }
                turns.append(Turn(kind: .notice, text: "Couldn't transcribe: \(error.localizedDescription)"))
            }
        }
    }

    /// A new selection starts a new conversation.
    func pointed(at rect: CGRect, on screen: NSScreen) {
        stop(clearHighlight: false) // the new selection is already highlighted
        askedSinceSelection = false
        failed = false
        serial += 1
        turns = []
        history = []
        revealed = false
        previewedFor = nil
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let app = Exclusions.app(at: center)
        if Exclusions.isExcluded(app) {
            capture = nil
            status = "Glance never looks at \(app?.localizedName ?? "this app"). Point somewhere else."
            return
        }
        status = "Reading your selection…"
        let appName = app?.localizedName ?? "Unknown app"
        capture = Task {
            do {
                let packet = try await ContextPacket.capture(selection: rect, on: screen, appName: appName)
                status = "Pointing at \(appName). Ask about it."
                return packet
            } catch {
                status = "Couldn't read the screen: \(error.localizedDescription)"
                failed = true
                return nil
            }
        }
    }

    func submit() {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        input = ""
        ask(q, shown: q)
    }

    func followUp(_ f: Mode.FollowUp) { ask(f.prompt, shown: f.label) }

    func point() { onPoint?() }

    func stop(clearHighlight: Bool = true) {
        if clearHighlight, Self.clearsHighlight(.stop, guideActive: guide.active, asked: askedSinceSelection) { onClearHighlight?() }
        guide.stop()
        speaker.stop()
        answering?.cancel()
        answering = nil
        busy = false
    }

    /// `spokenAt`: when the user released ⌥Space, for the release → first spoken word log.
    private func ask(_ question: String, shown: String, spokenAt: Date? = nil) {
        // Guide first, so no other mode can take over a "show me how" line. Inside a session, Guide replaces its own step.
        let rule = Guide.intent(question) ?? (guide.active ? "session active" : mode.name == Mode.guide.name ? "Guide chip" : nil)
        let toGuide = rule != nil
        log.notice("guide: route \(toGuide ? "guide" : "explain", privacy: .public) (\(rule ?? "no rule matched", privacy: .public))")
        if busy && !(toGuide && guide.active) { stop() } // a spoken question replaces the one being answered
        if toGuide {
            turns.append(Turn(kind: .user, text: shown))
            _ = guide.handle(question)
            return
        }
        if Self.clearsHighlight(.newQuestion, guideActive: false, asked: askedSinceSelection) { onClearHighlight?() }
        askedSinceSelection = true
        failed = false
        serial += 1
        busy = true
        turns.append(Turn(kind: .user, text: shown))
        answering = Task {
            let began = Date() // log only: reading the selection and building memory count as thinking too
            defer { if !Task.isCancelled { busy = false } }
            let provider: AIProvider
            do { provider = try Providers.current() } catch {
                turns.append(Turn(kind: .notice, text: error.localizedDescription))
                failed = true
                return
            }
            let source = capture
            var packet = await source?.value
            // Stopped while the screen was being read (Stop, a new question or a new selection): send nothing,
            // and leave `revealed` and the history to whatever replaced this question.
            guard !Task.isCancelled else { return }
            // A new selection while waiting: this question belongs to the old one.
            guard capture == source else { return }
            let selectionSecs = Date().timeIntervalSince(began)
            // Recent activity joins every conversation; follow-ups refresh it when new pages were stored since.
            // Built and redacted off the main thread, while the screen is read.
            let newestSeen = packet?.memoryNewest ?? 0
            let memoryWork = timeline.map { tl in
                Task.detached(priority: .userInitiated) { () -> (built: MemoryContext.Built, redacted: (text: String, hits: Int), secs: Double)? in
                    let t0 = Date()
                    let since = Date().timeIntervalSince1970 - Double(Config.retentionMinutes * 60)
                    guard let rows = try? tl.recent(since: since), let newest = rows.first?.ts, newest > newestSeen,
                          let built = MemoryContext.build(rows: rows) else { return nil }
                    return (built, Redactor.redact(built.text), Date().timeIntervalSince(t0))
                }
            }
            // No selection: the front window's text (newest memory row, or a fresh read) joins the question. Text only.
            let screenStart = Date()
            if !(packet?.hasSelection ?? false), let now = await ScreenNow.read(timeline: timeline) {
                guard !Task.isCancelled, capture == source else { return }
                packet = (packet ?? .memoryOnly()).withScreenNow(app: now.app, title: now.title, text: now.text)
            }
            let screenSecs = Date().timeIntervalSince(screenStart)
            let memory = await memoryWork?.value
            guard !Task.isCancelled, capture == source else { return }
            if let memory {
                let withMemory = (packet ?? .memoryOnly()).withMemory(memory.built, redacted: memory.redacted)
                packet = withMemory
                capture = Task { withMemory }
            }
            log.notice("prep: selection \(selectionSecs, format: .fixed(precision: 2), privacy: .public) s, screen now \(screenSecs, format: .fixed(precision: 2), privacy: .public) s, memory \(memory?.secs ?? 0, format: .fixed(precision: 2), privacy: .public) s (in parallel with the screen)")
            let reveal = revealed || Redactor.userAskedToReveal(question)
            let target = (provider.name, provider.supportsImages)
            let announce = history.isEmpty || (reveal && !revealed) || Self.needsPreview(first: previewedFor, now: target)
            if announce { previewedFor = target }
            revealed = reveal
            var confirming = false
            let answer = ContextPacket.send(packet, history: history, question: question, reveal: reveal,
                                            announce: announce, mode: mode, provider: provider) { preview in
                confirming = preview.confirmPrompt != nil
                var text = "Sending to \(preview.providerName): "
                if preview.image == nil && preview.selectedText.isEmpty {
                    let screen = preview.memory.hasPrefix("On screen now")
                    let recent = !preview.memory.isEmpty && !(screen && preview.memoryPages == 0)
                    text += "your question" + (screen ? ", what's on screen now" : "") + (recent ? " and your recent activity" : "")
                        + (preview.memory.isEmpty ? "." : " (text).")
                } else {
                    text += preview.imagesSent ? "an image of your selection, and the text below." : "the selection’s text only (image stays on this Mac)."
                }
                if preview.revealed {
                    text += "\n⚠️ Not redacted: you asked Glance to look at hidden data (until your next selection)."
                } else {
                    text += preview.redactions > 0 ? "\n🔒 Hid \(preview.redactions) sensitive item(s)." : "\nNo sensitive items found."
                }
                if preview.image != nil || !preview.selectedText.isEmpty {
                    text += "\nSelected text:\n" + (preview.selectedText.isEmpty ? "(none found)" : preview.selectedText)
                }
                if !preview.memory.isEmpty {
                    text += "\n\n🧠 Memory included: \(preview.memoryPages) page(s) from \(preview.memoryApps) app(s), "
                        + "\(preview.memory.count.formatted()) characters, last \(Config.retentionMinutes) min (redacted):\n" + preview.memory
                }
                turns.append(Turn(kind: .preview, text: text, image: preview.image))
            }
            turns.append(Turn(kind: .assistant, text: ""))
            let index = turns.count - 1
            let tts = Voice.tts(muted: muted) { reason in
                Task { @MainActor [weak self] in self?.voiceNotice(Self.macVoiceNotice, detail: reason) }
            }
            speaker.onError = { [weak self] error in self?.voiceNotice(error.localizedDescription) }
            speaker.begin(tts) {
                if let spokenAt { log.notice("voice: release → first spoken audio \(Date().timeIntervalSince(spokenAt), format: .fixed(precision: 2), privacy: .public) s") }
            }
            do {
                var raw = ""
                // Log only: how long "Thinking…" lasted, and when the spoken "Say:" sentence was complete.
                let asked = Date()
                var firstToken = false, sayDone = false
                defer { log.notice("answer: total \(Date().timeIntervalSince(asked), format: .fixed(precision: 2), privacy: .public) s, \(raw.count, privacy: .public) characters") }
                for try await delta in answer {
                    guard !Task.isCancelled else { return } // turns may already belong to a new selection
                    raw += delta
                    if !firstToken {
                        firstToken = true
                        log.notice("answer: thinking \(Date().timeIntervalSince(began), format: .fixed(precision: 2), privacy: .public) s until the first word (\(asked.timeIntervalSince(began), format: .fixed(precision: 2), privacy: .public) s reading the screen and memory)")
                    }
                    if !sayDone, case .summary(_, true, _) = Voice.splitSpoken(raw) {
                        sayDone = true
                        log.notice("answer: Say line complete at \(Date().timeIntervalSince(asked), format: .fixed(precision: 2), privacy: .public) s")
                    }
                    turns[index].text = speaker.answer(raw)
                    answerRaw = (turns[index].id, raw)
                }
                // A cancelled stream just ends; it is not a finished answer and must not enter the history.
                guard !Task.isCancelled else { return }
                // Phase 4: Cancel on the Send/Cancel step ends the stream with nothing sent.
                if raw.isEmpty && confirming {
                    speaker.stop()
                    turns.remove(at: index)
                    turns.append(Turn(kind: .notice, text: "Cancelled. Nothing was sent."))
                    return
                }
                turns[index].text = speaker.answer(raw, final: true)
                history += [ChatMessage(role: .user, text: question), ChatMessage(role: .assistant, text: raw)]
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                if turns[index].text.isEmpty { turns.remove(at: index) }
                turns.append(Turn(kind: .notice, text: error.localizedDescription))
                failed = true
            }
        }
    }
}

struct PanelView: View {
    @ObservedObject var chat: ChatModel
    @ObservedObject var confirm = SendConfirm.shared
    @AppStorage("localOnly") private var localOnly = false
    @State private var atBottom = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Glance · \(chat.mode.name)", systemImage: "eye").font(.headline)
                Button { chat.mode = chat.mode.name == Mode.guide.name ? .explain : .guide } label: {
                    Label("Guide", systemImage: chat.mode.name == Mode.guide.name ? "hand.point.up.left.fill" : "hand.point.up.left")
                }
                .help(chat.mode.name == Mode.guide.name ? "Your next question starts a step-by-step Guide. Click to go back to Explain"
                      : "Step by step: Pip points at each button to click for your next question")
                if localOnly { LocalOnlyBadge() }
                Spacer()
                Button { chat.muted.toggle() } label: {
                    Image(systemName: chat.muted ? "speaker.slash" : "speaker.wave.2")
                }
                .help(chat.muted ? "Answers are text only. Click to read them aloud" : "Answers are read aloud. Click to mute")
                Button { chat.point() } label: { Label("Point", systemImage: "viewfinder") }
                    .help("Drag a box over something on screen")
                Button { chat.onShowMore?() } label: { Image(systemName: "xmark") }
                    .help("Close the chat (Pip stays)")
            }
            if chat.listening {
                Label("Listening… release \(Config.hotkeyDescription) to ask", systemImage: "mic.fill")
                    .font(.callout.bold()).foregroundStyle(.red)
            } else if chat.transcribing {
                Label("Transcribing…", systemImage: "waveform").font(.callout).foregroundStyle(.secondary)
            } else if let problem = Problem.fromStatus(chat.status) {
                ProblemCard(problem: problem, compact: true)
            } else {
                Text(chat.status).font(.callout).foregroundStyle(.secondary)
            }
            if let memory = Problem.memory(chat.memoryState) {
                ProblemCard(problem: memory, compact: true)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(chat.turns) { TurnView(turn: $0) }
                        if !chat.busy, chat.turns.last?.kind == .assistant {
                            HStack(spacing: 8) {
                                ForEach(chat.mode.followUps, id: \.label) { f in
                                    Button(f.label) { chat.followUp(f) }
                                        .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                                }
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                            .onAppear { atBottom = true }
                            .onDisappear { atBottom = false }
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Follow the stream only while the user is at the bottom; reading earlier text isn't yanked away.
                .onChange(of: chat.turns.last?.text) { if atBottom { proxy.scrollTo("bottom") } }
                .onChange(of: chat.turns.count) { if atBottom || chat.turns.last?.kind == .user { proxy.scrollTo("bottom") } }
                .overlay(alignment: .bottomTrailing) {
                    if !atBottom, !chat.turns.isEmpty {
                        Button { withAnimation { proxy.scrollTo("bottom") } } label: {
                            Label("Latest", systemImage: "arrow.down").font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.small)
                        .padding(8)
                        .help("Scroll to the latest message")
                    }
                }
            }

            if let prompt = confirm.prompt {
                HStack(spacing: 8) {
                    Label(prompt, systemImage: "lock.shield").font(.callout.bold())
                    Spacer()
                    Button("Cancel") { confirm.answer(false) }.keyboardShortcut(.cancelAction).buttonStyle(.bordered)
                    Button("Send") { confirm.answer(true) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
                .padding(10)
                .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.blue.opacity(0.25)))
                .help("Say \u{201C}send\u{201D} or \u{201C}cancel\u{201D} with \(Config.hotkeyDescription) too")
            }
            HStack(spacing: 8) {
                TextField("Ask about it…", text: $chat.input)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .onSubmit { chat.submit() }
                if chat.busy {
                    Button { chat.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                        .help("Stop the answer and the voice")
                } else {
                    Button { chat.submit() } label: { Label("Ask", systemImage: "arrow.up") }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(chat.input.isEmpty)
                }
            }
        }
        .padding(16)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct TurnView: View {
    let turn: ChatModel.Turn

    var body: some View {
        switch turn.kind {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(turn.text)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                    .textSelection(.enabled)
            }
        case .assistant:
            AnswerView(text: turn.text)
        case .preview:
            VStack(alignment: .leading, spacing: 8) {
                // Phase 4: big enough to see the blacked-out lines; click to enlarge.
                if let image = turn.image {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .onTapGesture { PreviewPeek.show(image) }
                        .help("Click to enlarge")
                }
                Text(turn.text).font(.caption).foregroundStyle(.secondary).lineLimit(12)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        case .notice:
            ProblemCard(problem: Problem.classify(turn.text))
        }
    }
}

extension ChatModel {
    /// Audit A2: show the "Sending to …" preview again when the provider or its image setting differs from
    /// what the conversation's first preview said.
    nonisolated static func needsPreview(first: (String, Bool)?, now: (String, Bool)) -> Bool {
        guard let first else { return true }
        return first != now
    }
}

/// Which parts of Glance are on screen (pure; selftested). Pip-only by default: a tap shows Pip with its one-line
/// field; the panel appears only after Show more or the menu's Show Glance.
struct GlanceSurface: Equatable {
    var pip = false
    var compact = false
    var panel = false

    enum TapAction: Equatable { case guideNext, hide, showToType }

    /// ⌥Space tap. Never starts pointing; the Point buttons do.
    mutating func tap(guideActive: Bool) -> TapAction {
        if guideActive { return .guideNext }
        if pip || panel { self = GlanceSurface(); return .hide }
        pip = true
        compact = true
        return .showToType
    }

    /// Show more / ✕ toggle the panel; Pip stays.
    mutating func showMore() {
        panel.toggle()
        pip = true
    }

    /// Menu Show Glance: true = show the panel, false = hide everything.
    mutating func menuShow() -> Bool {
        if pip || panel { self = GlanceSurface(); return false }
        pip = true
        panel = true
        return true
    }

    /// Clicking Pip: true = open the one-line field, false = hide.
    mutating func pipTapped() -> Bool {
        if compact || panel { self = GlanceSurface(); return false }
        pip = true
        compact = true
        return true
    }

    mutating func hold() { pip = true }
    mutating func hide() { self = GlanceSurface() }
}
