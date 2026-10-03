import AppKit
import Combine
import SwiftUI

/// Floating panel that sits above every app without stealing focus from it.
@MainActor
final class PanelController {
    private let panel: NSPanel
    private let chat = ChatModel()
    private let pointTool = PointTool()

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

        chat.onPoint = { [weak self] in self?.pointTool.start() }
        pointTool.onSelect = { [weak self] rect, screen in
            guard let self else { return }
            self.chat.pointed(at: rect, on: screen)
            self.focusInput()
        }
        pointTool.onCancel = { [weak self] in self?.focusInput() }
    }

    var isVisible: Bool { panel.isVisible }

    /// ⌥Space: show the panel and start pointing, or hide everything.
    func toggle() {
        if panel.isVisible {
            panel.orderOut(nil)
            pointTool.clear()
        } else {
            if let screen = NSScreen.main {
                let frame = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 24,
                                             y: frame.maxY - panel.frame.height - 24))
            }
            panel.orderFrontRegardless()
            pointTool.start()
        }
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
    var onPoint: (() -> Void)?

    let mode = Mode.explain
    private var capture: Task<ContextPacket?, Never>?
    private var history: [ChatMessage] = []
    private var answering: Task<Void, Never>?

    /// A new selection starts a new conversation.
    func pointed(at rect: CGRect, on screen: NSScreen) {
        stop()
        turns = []
        history = []
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
        answering?.cancel()
        answering = nil
        busy = false
    }

    private func ask(_ question: String, shown: String) {
        guard !busy else { return }
        busy = true
        turns.append(Turn(kind: .user, text: shown))
        answering = Task {
            defer { busy = false }
            let provider: AIProvider
            do { provider = try Providers.current() } catch {
                turns.append(Turn(kind: .notice, text: error.localizedDescription))
                return
            }
            let packet = await capture?.value
            let (message, answer) = ContextPacket.send(packet, question: question, history: history, mode: mode,
                                                       provider: provider) { preview in
                var text = "Sending to \(preview.providerName): "
                text += preview.imagesSent ? "selection + screen images, and the text below." : "on-screen text only (image stays on this Mac)."
                text += preview.redactions > 0 ? "\n🔒 Hid \(preview.redactions) sensitive item(s)." : "\nNo sensitive items found."
                text += "\nSelected text:\n" + (preview.selectedText.isEmpty ? "(none found)" : preview.selectedText)
                turns.append(Turn(kind: .preview, text: text, image: preview.image))
            }
            turns.append(Turn(kind: .assistant, text: ""))
            let index = turns.count - 1
            do {
                for try await delta in answer { turns[index].text += delta }
                history += [message, ChatMessage(role: .assistant, text: turns[index].text)]
            } catch is CancellationError {
            } catch {
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
                Button { chat.point() } label: { Label("Point", systemImage: "viewfinder") }
                    .help("Drag a box over something on screen")
            }
            Text(chat.status).font(.caption).foregroundStyle(.secondary)

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
