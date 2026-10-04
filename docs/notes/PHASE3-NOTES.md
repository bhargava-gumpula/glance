# Phase 3 notes (cross-app memory)

Context for a future chat that isn't obvious from the code. Settings and defaults: `DECISIONS.md`. Owner checklist and gotchas: `docs/HANDOFF.md` (Phase 3 sections). No keys or page text here.

## Architecture
- `Capture/MemoryRecorder.swift`: the 1 s loop. Exclusions, then capture of the focused window only, exclusions again, then OCR. `SnapshotGate` stores at most one row per 3 s and skips text identical to the last row for the same window. Also handles Pause, Forget, rolling deletion (about once a minute, also while paused), sleep/lock suspension and Low Power thinning. A generation counter drops captures that were in flight during Pause or Forget.
- `Capture/ActiveApp.swift`: Accessibility reads of the frontmost app and focused window (title, `AXDocument`, the page's `AXWebArea` `AXURL`), private-window markers, and secure input (`AXSecureTextField` or `IsSecureEventInputEnabled`). AX calls time out after 0.25 s. The browser chrome walk is cached per window element and title for 15 s.
- `Privacy/Exclusions.swift` (`memorySkipReason`): the single place that decides "don't capture": Glance itself, excluded apps, secure input, private markers, blocked URL or title.
- `Memory/Timeline.swift`: system SQLite with FTS5, `schema_version` migrations, WAL, `secure_delete`, FTS5 secure-delete, file 0600, folder excluded from Time Machine. `recent(since:)` feeds the memory context. FTS5 is kept for the Forget checks and future search.
- `Memory/MemoryContext.swift`: built at question time from the timeline rows. It contains an activity log (visits, oldest first, extractive gist) plus the de-duplicated text of every page. `ContextPacket.withMemory` redacts it as one block, and `ContextPacket.send()` is the only exit.

## Decisions and why
- **Front window only, never the whole screen:** less exposure, and each row is attributed to one app, title and URL, so exclusions apply to exactly what's captured. The SCK window must match the AX focused window's frame, otherwise nothing is captured.
- **Check 1 s / snapshot 3 s / keep 10 min:** owner request. Reading every second keeps the latest text fresh; storing every 3 s with the same-text rule saves storage. Forget = retention (10 min).
- **Dedupe (identical text, same window → no new row):** owner wanted to save storage. Side effect: a static page while the user talks produces no new rows. That's expected, not a skip.
- **Unreadable browser URL → stored without a URL:** owner decision after the "no MacBooks" report. Private markers and blocked titles still skip, and it's logged. Earlier this case was skipped ("unknown page"), which was too strict.
- **Full context on every question (not keyword snippets):** owner decision. DeepSeek is text-only and should understand what the user has been doing. Budget `Config.memoryContextMaxChars` = 60k chars. The activity log is never cut; the oldest pages shrink to their key lines first, then a hard cut. Also refreshed on follow-ups when newer rows exist.
- **Extractive gist instead of FoundationModels:** the full page text goes along anyway. An on-device LLM summary per stored page would add CPU continuously. Easy to add later in `MemoryContext.gist`.
- **No AppleScript for URLs:** avoids the Automation permission prompt.

## Root causes found
- **A19 (budget line dropped):** the old keyword-snippet retrieval only kept lines sharing a word with the question or selection, so "Budget: €1,200 max" never matched laptop specs. Fixed first by sending short windows whole, now superseded by the full context.
- **"No MacBooks in memory" (owner report):** the pages were stored, but memory was attached only when the question had a drag-box selection (`if let p = packet`). Voice questions without pointing sent no memory. Now every question carries it (`ContextPacket.memoryOnly()` when nothing is selected).
- **OCR cold start:** a cold Vision load that runs after NaturalLanguage work (the Redactor's name tagger) throws `CRImageReaderError error 1`, and OCR stays empty for the whole process. Retrying in-process for 60 s doesn't help; only a relaunch does. Fixes: the selftest warms up OCR first (as the app does at launch); `OCR.warmUp` logs the error and retries once; the panel says "OCR unavailable — relaunch Glance".
- **Partial Vision reads:** in 2 of about 10 selftest runs, Vision read 16 of 40 lines of the bench page; the same image read 40/40 in other processes. Not explained. In the app, a check occasionally stores less text.

## UNVERIFIED
- Safari/Chrome/Aside URL via `AXDocument`/`AXWebArea AXURL`. Aside (Chromium) URLs were confirmed read correctly in the owner's timeline. Safari and Chrome are not confirmed.
- Private-window detection (markers "Private Browsing", "Incognito", "InPrivate" in the title or browser chrome) has not been tested on real private windows.
- `AXManualAccessibility` for Chromium AX trees.

## Owner checks still not run (Phase 3)
- An excluded app (1Password, Keychain Access) or a focused password field adds zero rows; a Safari private window adds zero rows; Pause stops rows; Forget empties the table.
- Count and latest: `sqlite3 ~/Library/Application\ Support/Glance/timeline.sqlite "select count(*), max(datetime(ts,'unixepoch','localtime')) from snapshots"`
- Recent rows (no text): `sqlite3 ~/Library/Application\ Support/Glance/timeline.sqlite "select datetime(ts,'unixepoch','localtime'), app, window_title, url, length(text), length(thumb) from snapshots order by ts desc limit 10"`
- FTS after Forget: `sqlite3 ~/Library/Application\ Support/Glance/timeline.sqlite "select count(*) from snapshots_fts where snapshots_fts match 'laptop'"`
- Skip reasons: `/usr/bin/log stream --predicate 'subsystem == "ie.dublinhacx.glance"' --info | grep memory`
- CPU: `top -pid $(pgrep -x Glance) -l 20 -s 3 | grep -E '^ *[0-9]+ +Glance'`

## CPU (selftest, debug build)
- OCR 0.15–0.27 s per 1 s check on a 1440×900 window with text: roughly 15–27% of one core, continuously while recording (idle costs the same as active; nothing is skipped). Up to about 50% for windows at the 1920-pt cap. Low Power Mode checks every 3rd second.
- Thumbnail about 1.5 ms per snapshot. Memory context build + redaction about 170 ms for 49k chars, once per question.
- Not yet measured live in the app.

## phase7-wip (on hold, local only)
- A local branch in `~/Projects/glance-phase3` at c916e66, not pushed. Phase 7 was cancelled by the owner mid-way.
- Contains `Modes/Recap.swift` ("Where was I?": intent regex, newest-row-per-window with distinctive lines) and `Modes/Do.swift` ("Save comparison": intent regex, draft with redacted sources, `write()` with a numeric suffix and `.withoutOverwriting`), plus intent matching in `Mode.swift` (`matches`, `Mode.forQuestion`). Not wired into the panel; no selftests.
- Built on the old snippet retrieval. If resumed, rebase onto main and use `MemoryContext` instead.
