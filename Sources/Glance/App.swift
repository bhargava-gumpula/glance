import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotkey: Hotkey!
    private let panel = PanelController()
    private let onboarding = OnboardingController()
    private let settings = SettingsController()

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
        statusItem.button?.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Glance")

        let menu = NSMenu()
        menu.addItem(withTitle: "Show Glance (\(Config.hotkeyDescription))", action: #selector(togglePanel), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Permissions…", action: #selector(showOnboarding), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Glance", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = menu

        hotkey = Hotkey(keyCode: Config.hotkeyKeyCode, onPress: { [weak self] in self?.panel.toggle() })

        if !Permission.allGranted { onboarding.show() }
    }

    @objc private func togglePanel() { panel.toggle() }
    @objc private func showOnboarding() { onboarding.show() }
    @objc private func showSettings() { settings.show() }
}
