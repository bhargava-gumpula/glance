import AppKit
import SwiftUI

/// Pip-led first run: hello, the three permissions with a one-line why, and what stays on this Mac.
/// "Permissions…" in the menu reopens it on the permissions step.
@MainActor
final class OnboardingController {
    private var window: NSWindow?
    private let model = OnboardingModel()

    static var seen: Bool { UserDefaults.standard.bool(forKey: "onboardingSeen") }

    func show() {
        model.step = Self.seen ? .permissions : .hello
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
                styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false
            )
            w.title = "Welcome to Glance"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            model.close = { [weak w] in
                UserDefaults.standard.set(true, forKey: "onboardingSeen")
                w?.close()
            }
            w.contentView = NSHostingView(rootView: OnboardingView(model: model))
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable { case hello, permissions, privacy }
    @Published var step: Step = .hello
    var close: () -> Void = {}

    func next() {
        if let n = Step(rawValue: step.rawValue + 1) { step = n } else { close() }
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        // Re-reads permission state every second, so a grant in System Settings shows up here.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 14) {
                    PipSpriteView(state: model.step == .hello ? .talking : .idle, pointLeft: false)
                        .frame(width: 96, height: 72)
                        .accessibilityHidden(true)
                    SpeechBubble(text: pipLine)
                }
                Group {
                    switch model.step {
                    case .hello: hello
                    case .permissions: permissions
                    case .privacy: privacy
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                footer
            }
            .padding(.horizontal, 28).padding(.top, 36).padding(.bottom, 22)
        }
    }

    private var pipLine: String {
        switch model.step {
        case .hello: "Hi, I'm Pip! Point at anything on your screen and ask me about it."
        case .permissions: Permission.allGranted ? "All set. Thank you!" : "I need three permissions. Here's why each one helps."
        case .privacy: "Your screen is yours. Here's what stays on your Mac."
        }
    }

    private var hello: some View {
        VStack(alignment: .leading, spacing: 12) {
            Tip(symbol: "viewfinder", title: "Point and ask", text: "Tap \(Config.hotkeyDescription), drag a box over anything, then type a question.")
            Tip(symbol: "mic", title: "Or just talk", text: "Hold \(Config.hotkeyDescription), speak, and let go. I'll answer out loud.")
            Tip(symbol: "menubar.rectangle", title: "I live in the menu bar", text: "Look for the little penguin at the top of your screen.")
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Permission.allCases) { p in
                HStack(spacing: 12) {
                    Image(systemName: p.isGranted ? "checkmark.circle.fill" : p.symbol)
                        .font(.title2)
                        .foregroundStyle(p.isGranted ? Color.green : Color.accentColor)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.title).font(.body.weight(.semibold))
                        Text(p.reason).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if p.isGranted {
                        Text("Allowed").font(.callout).foregroundStyle(.green)
                    } else {
                        Button("Allow") { p.request() }.buttonStyle(.borderedProminent)
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityElement(children: .combine)
            }
            Text("After allowing Screen Recording, macOS may ask you to reopen Glance.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 12) {
            Tip(symbol: "internaldrive", title: "Memory stays on this Mac",
                text: "I remember the last \(Config.retentionMinutes) minutes of what you looked at, only on this Mac. Pause or forget it any time from the menu bar.")
            Tip(symbol: "lock", title: "Some things I never record",
                text: "Password fields, private browser windows, banking sites and apps like Keychain Access.")
            Tip(symbol: "paperplane", title: "Only sent when you ask",
                text: "Your question, your selection and recent activity go to the AI you chose, with cards, emails and keys blacked out first. You see exactly what's sent.")
            Tip(symbol: "key", title: "Keys stay in your Keychain", text: "API keys are never written to a file.")
        }
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(OnboardingModel.Step.allCases, id: \.self) { s in
                    Circle().fill(s == model.step ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                }
            }
            .accessibilityHidden(true)
            Spacer()
            if model.step == .permissions && !Permission.allGranted {
                Button("Later") { model.next() }
            }
            Button(model.step == .privacy ? "Start using Glance" : model.step == .hello ? "Nice to meet you" : "Continue") { model.next() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }
}

private struct SpeechBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.title3.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(red: 0.094, green: 0.373, blue: 0.647), lineWidth: 2))
            .accessibilityLabel("Pip says: \(text)")
    }
}

private struct Tip: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Color.accentColor).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
