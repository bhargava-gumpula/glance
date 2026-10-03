# Handoff

## Status
**Phase 0 (setup): done, gate passed (2026-10-03).** Phase 1 has not started; it begins in a new chat.

Built so far:
- SwiftPM menu-bar app (`Sources/Glance`): eye icon, menu (Show / Permissions / Quit)
- ⌥Space global hotkey (Carbon; reports press and release for hold-to-talk later) toggles a floating panel
- Permissions onboarding for Screen Recording, Accessibility and Microphone (auto-opens until all are granted)
- `Config.swift` (all defaults), `--selftest` harness, `scripts/build-app.sh`, `scripts/selftest.sh`
- Private GitHub repo created; nothing pushed until the owner confirms

## Phase 0 gate checklist
- [x] `./scripts/selftest.sh` passes
- [x] App builds, launches, menu-bar icon appears
- [x] Owner: ⌥Space opens/closes the panel
- [x] Owner: create the "Glance Dev" signing certificate (below), then rebuild
- [x] Owner: granted all three permissions (on the ad-hoc build)
- [x] After the certificate exists: rebuild and confirm permissions are **still granted** (verified 2026-10-03 after a forced full recompile)

## Create the "Glance Dev" certificate (owner, 5 min)
1. Open `/System/Library/CoreServices/Certificate Assistant.app` (on macOS 27 it is not in the Keychain Access menu) → **Create a Certificate…**
2. Name: `Glance Dev`. Identity Type: **Self-Signed Root**. Certificate Type: **Code Signing**. Click Create.
3. Run `./scripts/build-app.sh`. The warning about ad-hoc signing should be gone.
4. The first time codesign uses the key, macOS asks for keychain access. Choose **Always Allow**.

## Owner requests for later
- Make the panel a more interactive chat (conversation thread, follow-ups). Fits Phase 1 (panel + Explain follow-ups) and Phase 8 (polish).

## Findings / gotchas
- **No Xcode, only Command Line Tools (Swift 6.4, macOS 27.0 SDK).** The CLT lack SwiftUI's macro plugin, so `@State`, `@Observable` and other SwiftUI macros **don't compile**. Until Xcode is installed, use AppKit or macro-free SwiftUI (e.g. `TimelineView`, plain `ObservableObject` classes). Installing Xcode removes this limit. `sudo mas install 497799835` needs the owner's password.
- "Glance Dev" is self-signed, so it shows as `CSSMERR_TP_NOT_TRUSTED` and is missing from `security find-identity -v`. `build-app.sh` checks without `-v`; codesign uses it fine. No need to mark it trusted.
- Switching signing identity invalidates old grants: remove the stale Glance entries in Privacy & Security (or `tccutil reset ScreenCapture|Accessibility ie.dublinhacx.glance`) and re-grant. A failed/partial codesign run that still launches the app can drop the Accessibility grant.
- Ad-hoc signing changes the signature every build, so macOS revokes permissions. That's why the certificate matters.
- This session couldn't take screenshots (no Screen Recording permission), so gate screenshots need the owner or a session that has it.
- Bundle ID: `ie.dublinhacx.glance`. App output: `build/Glance.app`.

## Next: Phase 1 (end-to-end slice). See docs/PLAN.md
Point tool → ContextPacket (basic redaction + send preview) → AIProvider (Claude + OpenAI-compatible presets: DeepSeek, OpenAI, Local) → streamed Explain answer. Load the `claude-api` skill before writing the Claude provider.
