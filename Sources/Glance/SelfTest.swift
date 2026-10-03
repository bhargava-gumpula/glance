import Foundation

/// `Glance --selftest`: assert-style checks, non-zero exit on failure.
/// Each phase adds its checks here.
enum SelfTest {
    static func run() -> Never {
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            print("\(condition ? "PASS" : "FAIL")  \(name)")
            if !condition { failures += 1 }
        }

        check(Config.captureIntervalSeconds > 0, "capture interval is positive")
        check(Config.retentionMinutes > 0, "retention is positive")
        check(Config.excludedApps.contains("com.apple.keychainaccess"), "Keychain Access is excluded by default")
        check(["claude", "deepseek", "openai", "local"].contains(Config.provider), "default provider is known")

        print(failures == 0 ? "selftest: all passed" : "selftest: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
