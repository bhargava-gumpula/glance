# Task: Glance Phase 8 (visual polish)

**Owner:** the "Phase 8" chat. **Phases 4 and 5 are running in parallel.**

## Read first
- `docs/HANDOFF.md`
- `docs/notes/UI-NOTES.md`: your own previous notes (Pip architecture, API, decisions)
- `docs/PLAN.md` (Phase 8, Demo), `docs/PITCH.md`, `docs/tasks/UI-POLISH.md` (the original queue)

## Scope (visuals and wiring only)
1. **Pip-led onboarding:**
   - a friendly first-run flow where Pip introduces itself
   - the 3 permissions, each with a one-line "why"
   - "what stays on your Mac" in plain language
   - it replaces the plain permissions window
2. **Designed error states** in the panel and Pip's bubble instead of raw text:
   - no API key
   - provider/HTTP error (e.g. Azure "deployment not ready" → friendly text plus a "details" disclosure)
   - no network
   - permission missing
   - "Using Mac voice"
   - memory paused / not saving (with the reason)
   - "OCR unavailable — relaunch"
3. **App icon and menu-bar glyph:**
   - an 8-bit penguin app icon (`.icns` built with `iconutil` from generated PNGs, wired into `scripts/build-app.sh`)
   - a template menu-bar glyph that still shows the recording / paused / not-saving states
4. **Panel polish:** spacing, typography, readable code blocks and tables in answers, a clear Stop button, a scroll-to-latest button.

## Coordination
- **Phase 4 owns** `Settings.swift`, the menu items, `ContextPacket.send` and its new Send/Cancel confirm UI, the "Local only" badge, and the bigger preview. **Don't edit those.** Instead, SendMessage the "Phase 4" chat with design suggestions (e.g. how the Local-only badge and the confirm card should look).
  - The **Settings regroup** from UI-POLISH waits until Phase 4 merges. Don't start it.
- **Phase 5 owns** `Guide/*` and drives Pip via `pet.point/say/goHome`. **Don't change those signatures.** If you change Pip behaviour, tell the "Phase 5" chat.
- **Shared:** `Panel.swift` and `SelfTest.swift`. Small, additive edits only, and message the other chat if you touch an area it's working in.
- **Your own worktree:** `git -C ~/Projects/glance worktree add ../glance-phase8 -b phase8` (the old `glance-ui` worktree can be removed or ignored).
- **Never merge into `main`.** The Orchastrator merges Phase 4 → Phase 5 → Phase 8.
- **No `build-app.sh` or launch** without the owner's OK in your chat.
- Normal effort, with selftests for any logic.

## Phase 8 check (then STOP)
- selftest passes.
- The owner sees: the new onboarding, the icon in Finder and the Dock-less menu bar, the error states (e.g. remove a key or turn off Wi-Fi), and the panel polish.

## Report back
SendMessage **"Orchastrator"** with:
- commits
- each check item, pass/fail
- whether the branch merges cleanly with `main`, `phase4` and `phase5`
- open issues
