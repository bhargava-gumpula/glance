import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotkey: Hotkey!
    private let panel = PanelController()
    private let onboarding = OnboardingController()
    private let settings = SettingsController()
    private let memory = MemoryRecorder()
    private let memoryStatus = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause Memory", action: #selector(togglePause), keyEquivalent: "")

    static func main() {
        if CommandLine.arguments.contains("--selftest") { SelfTest.run() }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // menu-bar app, no Dock icon
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.addItem(withTitle: "Show Glance (\(Config.hotkeyDescription))", action: #selector(togglePanel), keyEquivalent: "")
        menu.addItem(.separator())
        memoryStatus.isEnabled = false
        menu.addItem(memoryStatus)
        menu.addItem(pauseItem)
        menu.addItem(withTitle: "Forget Last \(Config.forgetMinutes) Minutes", action: #selector(forget), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Permissions…", action: #selector(showOnboarding), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Glance", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = menu

        // Capture indicator: eye = recording, eye.slash = paused or off, eye with a dot = skipping this window.
        memory.onChange = { [weak self] in self?.showMemoryState($0) }
        showMemoryState(memory.state)
        panel.timeline = memory.timeline
        memory.start()

        hotkey = Hotkey(keyCode: Config.hotkeyKeyCode,
                        onPress: { [weak self] in self?.panel.keyDown() },
                        onRelease: { [weak self] in self?.panel.keyUp() })

        // Load Vision's models now so the first real question doesn't hang.
        Task.detached(priority: .utility) {
            let warm = OCR.warmUp()
            log.notice("OCR warm-up took \(warm.seconds, format: .fixed(precision: 1), privacy: .public) s")
        }

        if !Permission.allGranted { onboarding.show() }
    }

    @objc private func togglePanel() { panel.toggle() }
    @objc private func showOnboarding() { onboarding.show() }
    @objc private func showSettings() { settings.show() }
    @objc private func togglePause() { memory.paused.toggle() }
    @objc private func forget() {
        let n = memory.forgetRecent()
        log.notice("memory: forgot \(n, privacy: .public) snapshot(s)")
    }

    private func showMemoryState(_ state: MemoryRecorder.State) {
        let (symbol, text): (String, String) = switch state {
        case .recording: ("eye", "Memory: on (last \(Config.retentionMinutes) min, on this Mac)")
        case .paused: ("eye.slash", "Memory: paused")
        case .skipping(let why): ("eye.trianglebadge.exclamationmark", "Memory: not saving (\(why))")
        case .off(let why): ("eye.slash", "Memory: off (\(why))")
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Glance: \(text)")
        memoryStatus.title = text
        pauseItem.title = state == .paused ? "Resume Memory" : "Pause Memory"
        pauseItem.isHidden = { if case .off = state { true } else { false } }()
    }
}
