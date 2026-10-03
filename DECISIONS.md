# Open decisions

Each open decision has a working default and exactly one place to change it.

| Decision | Default | Where to change |
|---|---|---|
| Product name | Glance | `Config.bundleID`, `scripts/build-app.sh` (Info.plist), README |
| Hotkey | ⌥Space | `Config.hotkeyKeyCode` / `hotkeyDescription` |
| Capture interval | 3 s | `Config.captureIntervalSeconds` (Settings override) |
| Memory retention | 15 min | `Config.retentionMinutes` (Settings override) |
| Default AI provider | Claude | `Config.provider`: claude / deepseek / openai / local |
| Default models | set in Phase 1 | provider presets (Phase 1) |
| ElevenLabs voice | set in Phase 2 | Settings (Phase 2) |
| Speak answers aloud | on | `Config.ttsEnabled` |
| Never-captured apps | Keychain, System Settings, Passwords, 1Password, Bitwarden | `Config.excludedApps` |
| Never-captured sites | set in Phase 3 | URL blocklist (Phase 3) |
| Redaction rules | set in Phase 1/4 | `Resources/redaction.json` |
| "Do" actions | save comparison only | `Modes/Do.swift` (Phase 7) |
| Visual style | system default | `UI/` (Phase 8) |
| Demo sites and Guide app | Safari product pages; export-to-PDF flow | docs/PLAN.md, Demo |
