import AppKit

/// Drag a box over any app. The box stays highlighted (click-through) until cleared.
@MainActor
final class PointTool {
    var onSelect: ((CGRect, NSScreen) -> Void)?
    var onCancel: (() -> Void)?
    private var window: NSWindow?

    var isPointing: Bool { window?.ignoresMouseEvents == false }

    func start() {
        clear()
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let w = KeyableWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .screenSaver
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.onDone = { [weak self, weak w] rect in
            guard let self, let w else { return }
            w.ignoresMouseEvents = true // keep the highlight, let clicks through
            self.onSelect?(w.convertToScreen(rect), screen)
        }
        view.onCancel = { [weak self] in self?.clear(); self?.onCancel?() }
        w.contentView = view
        window = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(view)
    }

    func clear() {
        window?.orderOut(nil)
        window = nil
    }
}

private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class SelectionView: NSView {
    var onDone: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    private var start: NSPoint?
    private var rect: CGRect?
    private var done = false

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { if !done { addCursorRect(bounds, cursor: .crosshair) } }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        rect = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let p = convert(event.locationInWindow, from: nil)
        rect = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let rect, rect.width > 8, rect.height > 8 else { rect = nil; needsDisplay = true; return }
        done = true
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
        onDone?(rect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) } // Esc
    }

    override func draw(_ dirtyRect: NSRect) {
        if !done {
            NSColor.black.withAlphaComponent(0.18).setFill()
            bounds.fill()
        }
        guard let rect else { return }
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        if !done {
            NSColor.clear.setFill()
            rect.fill(using: .copy)
        }
        NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
        path.fill()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 3
        path.stroke()
    }
}
