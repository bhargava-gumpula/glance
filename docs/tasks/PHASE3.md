# Task: Glance Phase 3 (cross-app memory)

Phases 0–2 are on `origin/main`. Phase 2's code is done; the owner is still doing its hands-on voice checks in the running app.

## Read first, in order
1. `docs/HANDOFF.md`: current state, gotchas
2. `docs/PLAN.md`: the Phase 3 section, plus "Designed for undecided choices"
3. `docs/research/phase3-memory.md`: ScreenCaptureKit, Vision OCR, app/title/URL, secure fields and SQLite with FTS5, with type-checked snippets. Check every UNVERIFIED item before relying on it.
4. `DECISIONS.md`

## Work isolation (important)
- Work in a **separate git worktree** on branch `phase3`:
  ```bash
  cd ~/Projects/glance && git worktree add ../glance-phase3 -b phase3
  ```
  Don't edit `~/Projects/glance` itself. Other chats share it: the UI chat works in `../glance-ui` on branch `ui`.
- **Don't run `scripts/build-app.sh` without asking the owner first,** because it kills and relaunches the Glance they're testing. Use `swift build` and `.build/debug/Glance --selftest` in your worktree. When you need the real app for the check, ask the owner first.
- Don't merge into `main` and don't push `main`. Pushing your `phase3` branch is fine. The orchestrator coordinates the merge after Phase 2's check passes.

## Scope
1. **Recorder:**
   - `SCScreenshotManager` snapshot every `Config.captureIntervalSeconds` (3 s), excluding Glance's own windows and `Config.excludedApps`
   - skip unchanged frames (cheap downscaled diff)
   - reuse Phase 1's OCR (`OCR.swift`, already warmed up at launch)
2. **Timeline:**
   - SQLite (system `libsqlite3`) with a `schema_version` table and migrations
   - FTS5 search over the OCR text
   - stores app, window title, URL, text, timestamp and a **small** thumbnail, never full frames
   - check that FTS5 is available at startup
3. **Exclusions before OCR or storage:**
   - excluded apps
   - a URL blocklist in `Config` (banks, login and payment pages; the user can add more)
   - private/incognito windows (skip when unknown)
   - any frame while a secure (password) field is focused (`AXSecureTextField` + `IsSecureEventInputEnabled()`)
4. **Controls:**
   - always-visible capture indicator in the menu bar (e.g. eye icon state), with pause/resume
   - "Forget last 15 min" (deletes rows, FTS entries and thumbnails)
   - automatic rolling deletion after `Config.retentionMinutes`
5. **Use the memory when asking:**
   - recent timeline snippets that match the question (FTS) go into the existing `ContextPacket` as **text**, redacted by the existing Redactor
   - Phase 1's rule stands: only the selected region's image is sent, and the timeline only leaves the Mac inside a question via `ContextPacket.send()`
   - no background cloud calls, no cloud summaries
6. **Self-tests:** migrations, FTS insert and search, exclusion matching (apps, URLs, secure field), retention and forget deletion, and that a memory snippet is redacted before it reaches the packet.

## Rules
- Smallest complete change. Follow the existing patterns, with `Config.swift` as the single source of defaults. Update DECISIONS.md.
- No keys in code, logs or commits. CPU must stay reasonable: measure it and report.
- Tell the owner that macOS may ask for Automation permission if you use AppleScript to read the browser URL.

## Phase 3 check (then STOP; don't start Phase 4)
- Browse 2 laptop pages (docs/DEMO.md) and type the budget note (`demo/budget-note.txt`) into Notes. On the 3rd laptop, point and ask "How is this different from the earlier ones?" The answer uses all three and the budget.
- An excluded app or a focused password field adds **zero** rows. Pause stops capture. Forget deletes the rows (check with a query).
- CPU is reasonable (report the numbers). selftest passes.
- Update `docs/HANDOFF.md` on your branch, commit, push the `phase3` branch.

## When done, report back
SendMessage to **"Orchastrator"** with:
- what changed
- the branch and commit hash(es)
- each check item, pass/fail
- CPU numbers
- whether the branch merges cleanly with the current `main`
- open issues and owner actions

Do this even if you're blocked.
