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
    private let localOnlyItem = NSMenuItem(title: "Local Only", action: #selector(toggleLocalOnly), keyEquivalent: "")
    private var localOnlyWatch: NSObjectProtocol?

    static func main() {
        if CommandLine.arguments.contains("--selftest") { SelfTest.run() }
        if let i = CommandLine.arguments.firstIndex(of: "--make-iconset"), i + 1 < CommandLine.arguments.count {
            exit(AppIcon.writeIconset(to: URL(fileURLWithPath: CommandLine.arguments[i + 1])) == AppIcon.sizes.count ? 0 : 1)
        }
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
        menu.addItem(localOnlyItem)
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Permissions…", action: #selector(showOnboarding), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Glance", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = menu
        // Phase 4: the menu item, Settings toggle and badges all read UserDefaults "localOnly".
        showLocalOnly()
        localOnlyWatch = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showLocalOnly() }
        }

        // Capture indicator: the menu-bar penguin's badge shows recording, paused/off or skipping this window.
        memory.onChange = { [weak self] in self?.showMemoryState($0) }
        showMemoryState(memory.state)
        panel.timeline = memory.timeline
        memory.start()

        hotkey = Hotkey(keyCode: Config.hotkeyKeyCode,
                        onPress: { [weak self] in self?.panel.keyDown(at: $0) },
                        onRelease: { [weak self] in self?.panel.keyUp(at: $0) })

        // Load Vision's models now so the first real question doesn't hang.
        Task.detached(priority: .utility) {
            let warm = OCR.warmUp()
            log.notice("OCR warm-up took \(warm.seconds, format: .fixed(precision: 1), privacy: .public) s")
            if warm.text.isEmpty {
                await MainActor.run { self.panel.showStatus("OCR unavailable — relaunch Glance.") }
            }
        }

        if !Permission.allGranted || !OnboardingController.seen { onboarding.show() }
    }

    @objc private func togglePanel() { panel.toggle() }
    @objc private func showOnboarding() { onboarding.show() }
    @objc private func showSettings() { settings.show() }
    @objc private func togglePause() { memory.paused.toggle() }
    @objc private func toggleLocalOnly() { UserDefaults.standard.set(!Config.localOnly, forKey: "localOnly") }

    private func showLocalOnly() {
        localOnlyItem.state = Config.localOnly ? .on : .off
        localOnlyItem.toolTip = "AI, speech and voice stay on this Mac; every other address is blocked."
    }
    @objc private func forget() {
        let n = memory.forgetRecent()
        log.notice("memory: forgot \(n, privacy: .public) snapshot(s)")
    }

    private func showMemoryState(_ state: MemoryRecorder.State) {
        let text = switch state {
        case .recording: "Memory: on (last \(Config.retentionMinutes) min, on this Mac)"
        case .paused: "Memory: paused"
        case .skipping(let why): "Memory: not saving (\(why))"
        case .off(let why): "Memory: off (\(why))"
        }
        // Phase 8: a template penguin with a state badge (paused bars, "!" for not saving, a slash for off).
        statusItem.button?.image = MenuBarGlyph.image(for: state, description: "Glance: \(text)")
        panel.showMemory(state)
        memoryStatus.title = text
        pauseItem.title = state == .paused ? "Resume Memory" : "Pause Memory"
        pauseItem.isHidden = { if case .off = state { true } else { false } }()
    }
}
