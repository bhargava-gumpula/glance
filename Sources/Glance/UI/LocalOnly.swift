import AppKit
import SwiftUI

/// Phase 4: the "Local only" badge shown in the panel and on Pip while nothing may leave the Mac.
struct LocalOnlyBadge: View {
    var body: some View {
        Label("Local only", systemImage: "lock.laptopcomputer")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(.green)
            .background(Color.green.opacity(0.15), in: Capsule())
            .background(Color(nsColor: .windowBackgroundColor), in: Capsule()) // readable over any screen behind Pip
            .help("Nothing leaves this Mac.")
            .accessibilityLabel("Local only mode is on")
    }
}

/// Click-to-enlarge for the "Sending to …" preview image, so the blacked-out lines are easy to see.
@MainActor
enum PreviewPeek {
    private static var window: NSWindow?

    static func show(_ image: NSImage) {
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1200, height: 800)
        let scale = min(1, screen.width * 0.7 / max(image.size.width, 1), screen.height * 0.7 / max(image.size.height, 1))
        let size = NSSize(width: max(240, image.size.width * scale), height: max(160, image.size.height * scale))
        let w = window ?? NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "What Glance would send"
        w.isReleasedWhenClosed = false
        w.level = .floating
        let view = NSImageView(image: image)
        view.imageScaling = .scaleProportionallyUpOrDown
        w.contentView = view
        w.setContentSize(size)
        w.center()
        window = w
        w.orderFrontRegardless()
    }
}
