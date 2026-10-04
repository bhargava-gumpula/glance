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
        pet = PetController(chat: chat)
        pet.show()

        chat.onPoint = { [weak self] in self?.pointTool.start() }
        pointTool.onSelect = { [weak self] rect, screen in
            guard let self else { return }
            self.chat.pointed(at: rect, on: screen)
            self.pet.point(at: rect, ring: false)
            self.focusInput()
        }
        pointTool.onCancel = { [weak self] in self?.focusInput() }
        pet.onTap = { [weak self] in self?.petTapped() }
    }

    /// Clicking Pip opens the chat to message it (or hides the chat).
    private func petTapped() {
        if panel.isVisible { hide() } else { show(pointing: false); focusInput() }
    }

    private func hide() {
        panel.orderOut(nil)
        pointTool.clear()
        pet.goHome()
    }

    var isVisible: Bool { panel.isVisible }

    func showStatus(_ text: String) { chat.status = text }

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
            if !self.panel.isVisible { self.show(pointing: false) }
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
            toggle()
        } else {
            // The release can beat the hold timer; the question needs the panel either way.
            if !panel.isVisible { show(pointing: false) }
            chat.askFromRecording()
        }
    }

    nonisolated static func isTap(pressed: TimeInterval, released: TimeInterval) -> Bool {
        released - pressed < Config.holdToTalkSeconds
    }

    /// ⌥Space: show the panel and start pointing, or hide everything.
    func toggle() {
        if panel.isVisible {
            hide()
        } else {
            show(pointing: true)
        }
    }

    private func show(pointing: Bool) {
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            // Left of Pip's top-right home, so Pip and its bubble don't cover the chat.
            panel.setFrameOrigin(NSPoint(x: frame.maxX - PetController.size.width - 8 - panel.frame.width,
                                         y: frame.maxY - panel.frame.height - 24))
        }
        panel.orderFrontRegardless()
        pet.appear()
        if pointing { pointTool.start() }
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
    @Published var status = "Drag a box over anything, then ask about it."
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
    var timeline: Timeline?

    let mode = Mode.explain
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
        stop()
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

    func stop() {
        speaker.stop()
        answering?.cancel()
        answering = nil
        busy = false
    }

    /// `spokenAt`: when the user released ⌥Space, for the release → first spoken word log.
    private func ask(_ question: String, shown: String, spokenAt: Date? = nil) {
        if busy { stop() } // a spoken question replaces the one being answered
        serial += 1
        busy = true
        turns.append(Turn(kind: .user, text: shown))
        answering = Task {
            defer { if !Task.isCancelled { busy = false } }
            let provider: AIProvider
            do { provider = try Providers.current() } catch {
                turns.append(Turn(kind: .notice, text: error.localizedDescription))
                return
            }
            let source = capture
            var packet = await source?.value
            // Stopped while the screen was being read (Stop, a new question or a new selection): send nothing,
            // and leave `revealed` and the history to whatever replaced this question.
            guard !Task.isCancelled else { return }
            // A new selection while waiting: this question belongs to the old one.
            guard capture == source else { return }
            // Recent activity joins every conversation; follow-ups refresh it when new pages were stored since.
            if let timeline {
                let since = Date().timeIntervalSince1970 - Double(Config.retentionMinutes * 60)
                if let rows = try? timeline.recent(since: since), let newest = rows.first?.ts, newest > (packet?.memoryNewest ?? 0),
                   let built = MemoryContext.build(rows: rows) {
                    let withMemory = (packet ?? .memoryOnly()).withMemory(built)
                    packet = withMemory
                    capture = Task { withMemory }
                }
            }
            let reveal = revealed || Redactor.userAskedToReveal(question)
            let target = (provider.name, provider.supportsImages)
            let announce = history.isEmpty || (reveal && !revealed) || Self.needsPreview(first: previewedFor, now: target)
            if announce { previewedFor = target }
            revealed = reveal
            let answer = ContextPacket.send(packet, history: history, question: question, reveal: reveal,
                                            announce: announce, mode: mode, provider: provider) { preview in
                var text = "Sending to \(preview.providerName): "
                if preview.image == nil && preview.selectedText.isEmpty {
                    text += "your question" + (preview.memory.isEmpty ? "." : " and your recent activity (text).")
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
                for try await delta in answer {
                    guard !Task.isCancelled else { return } // turns may already belong to a new selection
                    raw += delta
                    turns[index].text = speaker.answer(raw)
                    answerRaw = (turns[index].id, raw)
                }
                // A cancelled stream just ends; it is not a finished answer and must not enter the history.
                guard !Task.isCancelled else { return }
                turns[index].text = speaker.answer(raw, final: true)
                history += [ChatMessage(role: .user, text: question), ChatMessage(role: .assistant, text: raw)]
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                if turns[index].text.isEmpty { turns.remove(at: index) }
                turns.append(Turn(kind: .notice, text: error.localizedDescription))
            }
        }
    }
}

struct PanelView: View {
    @ObservedObject var chat: ChatModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Glance · \(chat.mode.name)", systemImage: "eye").font(.headline)
                Spacer()
                Button { chat.muted.toggle() } label: {
                    Image(systemName: chat.muted ? "speaker.slash" : "speaker.wave.2")
                }
                .help(chat.muted ? "Answers are text only. Click to read them aloud" : "Answers are read aloud. Click to mute")
                Button { chat.point() } label: { Label("Point", systemImage: "viewfinder") }
                    .help("Drag a box over something on screen")
            }
            if chat.listening {
                Label("Listening… release \(Config.hotkeyDescription) to ask", systemImage: "mic.fill")
                    .font(.callout.bold()).foregroundStyle(.red)
            } else if chat.transcribing {
                Label("Transcribing…", systemImage: "waveform").font(.callout).foregroundStyle(.secondary)
            } else {
                Text(chat.status).font(.caption).foregroundStyle(.secondary)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(chat.turns) { TurnView(turn: $0) }
                        if !chat.busy, chat.turns.last?.kind == .assistant {
                            HStack {
                                ForEach(chat.mode.followUps, id: \.label) { f in
                                    Button(f.label) { chat.followUp(f) }
                                }
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: chat.turns.last?.text) { proxy.scrollTo("bottom") }
                .onChange(of: chat.turns.count) { proxy.scrollTo("bottom") }
            }

            HStack {
                TextField("Ask about it…", text: $chat.input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { chat.submit() }
                if chat.busy {
                    Button("Stop") { chat.stop() }
                } else {
                    Button("Ask") { chat.submit() }.disabled(chat.input.isEmpty)
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
                    .padding(8)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
            }
        case .assistant:
            Text(markdown(turn.text.isEmpty ? "…" : turn.text)).textSelection(.enabled)
        case .preview:
            HStack(alignment: .top, spacing: 8) {
                if let image = turn.image {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 90, maxHeight: 70)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                Text(turn.text).font(.caption).foregroundStyle(.secondary).lineLimit(12)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        case .notice:
            Label(turn.text, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
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
