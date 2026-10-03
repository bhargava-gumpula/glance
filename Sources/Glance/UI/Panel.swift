import AppKit
import SwiftUI

/// Floating panel that sits above every app without stealing focus from it.
@MainActor
final class PanelController {
    private let panel: NSPanel

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 160),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered, defer: true
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: PanelView())
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            if let screen = NSScreen.main {
                let frame = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 24,
                                             y: frame.maxY - panel.frame.height - 24))
            }
            panel.orderFrontRegardless()
        }
    }
}

struct PanelView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Glance", systemImage: "eye")
                .font(.headline)
            Text("Point at anything and ask. (Coming in Phase 1.)")
                .foregroundStyle(.secondary)
            Text("Press \(Config.hotkeyDescription) to hide.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
