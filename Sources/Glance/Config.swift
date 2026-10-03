import Foundation

/// Every tunable default lives here. Settings overrides are stored in UserDefaults under the same key.
/// See DECISIONS.md for which open decision each value belongs to.
enum Config {
    static let bundleID = "ie.dublinhacx.glance"

    /// Global hotkey: Option + Space (Carbon key code 49 = space).
    static let hotkeyKeyCode: UInt32 = 49
    static let hotkeyDescription = "⌥Space"

    static var captureIntervalSeconds: Double { value("captureIntervalSeconds", default: 3) }
    static var retentionMinutes: Int { value("retentionMinutes", default: 15) }
    static var provider: String { value("provider", default: "claude") }
    static var ttsEnabled: Bool { value("ttsEnabled", default: true) }

    /// Apps that are never captured (bundle IDs).
    static var excludedApps: [String] {
        value("excludedApps", default: [
            "com.apple.keychainaccess",
            "com.apple.systempreferences",
            "com.apple.Passwords",
            "com.1password.1password",
            "com.bitwarden.desktop",
        ])
    }

    private static func value<T>(_ key: String, default fallback: T) -> T {
        UserDefaults.standard.object(forKey: key) as? T ?? fallback
    }
}
