import AppKit
import SwiftUI

@MainActor
final class OnboardingController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 300),
                styleMask: [.titled, .closable], backing: .buffered, defer: false
            )
            w.title = "Set up Glance"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: OnboardingView())
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct OnboardingView: View {
    var body: some View {
        // Re-reads permission state every second. TimelineView avoids @State, whose macro
        // plugin ships only with Xcode, not the Command Line Tools.
        TimelineView(.periodic(from: .now, by: 1)) { _ in content }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Glance needs three permissions")
                .font(.title3.bold())
            Text("Everything Glance captures stays on this Mac unless you ask a question.")
                .foregroundStyle(.secondary)
            ForEach(Permission.allCases) { permission in
                HStack {
                    Image(systemName: permission.isGranted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(permission.isGranted ? .green : .secondary)
                    VStack(alignment: .leading) {
                        Text(permission.title).bold()
                        Text(permission.reason).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !permission.isGranted {
                        Button("Allow") { permission.request() }
                    }
                }
            }
            Text("Screen Recording may need Glance to be reopened after you allow it.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
    }
}
