# Handoff

## Status
**Phase 0 (setup): done, gate passed (2026-10-03).**
**Phase 1 (end-to-end slice): done, gate passed (2026-10-03)** with DeepSeek (via the owner's Azure AI Foundry endpoint, text-only). Claude and OpenAI weren't tested (no keys yet); Ollama isn't installed. **Phase 2 (voice): built, owner checks pending (2026-10-03).** See "Phase 2" below.
**Phase 3 (cross-app memory): built on branch `phase3`, owner checks pending (2026-10-03).** See "Phase 3" below.

Phase 1 adds:
- ⌥Space shows the panel and starts the **PointTool**: drag a box over any app (Esc skips). The box stays highlighted and lets clicks through. The "Point" button in the panel starts a new one.
- **ContextPacket** (`AI/ContextPacket.swift`): ScreenCaptureKit capture of **only the selected region** (owner request; the rest of the screen is never captured or sent), without Glance or excluded apps → on-device Vision OCR → **Redactor** → any OCR line with a hit is blacked out in the images. `ContextPacket.send()` is the only path that sends screen content; it redacts the question too and puts the "Sending to …" preview (thumbnail + text + "Hid N sensitive items") in the thread before the request starts.
- Pointing at an excluded app (`Config.excludedApps`) is refused. Excluded apps are also cut out of every screenshot.
- **AIProvider** + `AnthropicProvider` (raw HTTP/SSE, `claude-opus-5-5`, effort low, server-side refusal fallback on) + `OpenAICompatProvider` (DeepSeek, OpenAI, Local). Text-only models get OCR text instead of images.
- **Settings…** in the menu (⌘,): provider, model, address, "can see images", API key → Keychain (service `ie.dublinhacx.glance`, account = provider id).
- Panel is a **chat thread**: streamed answers, Explain more / Example follow-ups, Stop, typed follow-up questions. A new selection starts a new thread.

## After the Phase 1 gate (owner request, 2026-10-03)
- Redaction widened (see DECISIONS.md "Redaction rules"). 80 selftest checks, including product-page lines that must stay untouched.
- Override: if the question explicitly asks to see hidden data ("don't redact", "unredact", "show the redacted email", "it's okay to see my address"), `send()` uses the raw copy kept in memory. It stays on until the next selection, and the preview shows ⚠️ Not redacted. Excluded apps stay excluded.
- `testdata/product.html` has a fake "Account details" block for testing.
- Known limits: single first names aren't caught (two-word names only, so day names like "Tue" aren't flagged); famous people's names are redacted too; addresses without a street-type word or Eircode are missed.

## Phase 1 gate checklist (owner)
- [x] `./scripts/selftest.sh` passes (redactor + request format per provider)
- [x] DeepSeek key saved in Settings (Azure endpoint, model `DeepSeek-V4.1-Flash`, images off)
- [ ] Claude / OpenAI: run the same check once keys are added
- [x] (DeepSeek) `open testdata/product.html` in Safari (a fake laptop page). ⌥Space → drag over the Memory/Storage rows → ask "Is 16 GB enough for college?" → grounded answer streams in, quoting the spec. Repeat per provider.
- [x] Drag over the "Saved payment" line → the preview shows `[CARD]` and `[EMAIL]` and "Hid 2 sensitive item(s)", and the thumbnail shows a black box.
- [ ] (not reported yet) Try "Explain more" and "Example", and a typed follow-up.
- [ ] Ollama: not installed, so skipped.

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

- SwiftUI here: `@State` (and other macros) fail without Xcode, but `ObservableObject` + `@Published` + `@ObservedObject` compile fine. That's what the panel and Settings use.
- The Address field accepts a full endpoint (e.g. Azure's `…/openai/v1/chat/completions`); only the first line is kept and the endpoint path is stripped (`Config.normalizedBaseURL`). Azure hosts also get an `api-key` header. Keys go only in the API key field, which saves to Keychain.
- Computer-use automation can't drive Glance (it isn't in its app list), so point-and-ask checks need the owner.
- API keys are read from Keychain once per launch and cached in memory (`Keychain.cache`). If macOS asks for the login password, click **Always Allow**; a rebuild can ask once more because the signature changes.
- The first `codesign` after a change can wait on a hidden keychain prompt; the owner has to allow it (Always Allow).
- The Claude request uses beta `server-side-fallback-2026-07-01` with `fallbacks: "default"`. If Anthropic ever rejects it, delete those two lines in `AnthropicProvider.swift`.
- OpenAI default model `gpt-5` is a guess at a safe current id; change it in Settings if needed.


## Phase 2 (voice)
- **OCR warm-up:** `OCR.warmUp()` runs one tiny OCR in the background at launch. Timing goes to the log (below). Measured: 0.1 s inside the app right after a run; a fresh CLI process (`--selftest`) still pays ~27 s cold every time, so the selftest takes about half a minute.
- **Hold ⌥Space to talk** (≥ 0.3 s; a shorter tap toggles the panel as before, now on key-up). Recording starts on key-down so the first word isn't clipped; the panel shows "Listening…" then "Transcribing…". Holding again stops the current spoken answer (barge-in) and a spoken question replaces one still being answered.
- **Speech-to-text:** `Voice/Voice.swift`, protocol `SpeechToText`: ElevenLabs `scribe_v2` (16 kHz mono WAV, 6 s timeout) → on any failure Apple `SFSpeechRecognizer` (on-device when supported). Without an ElevenLabs key it's Apple only. Questions transcribed on-device show "(on-device)".
- **Spoken vs on-screen answers (owner request):** every answer opens with a "Say: …" line (1-2 short sentences) that is read aloud and hidden; the full, more detailed answer is shown on screen. If a model skips the line, the start of the answer is spoken instead (`Voice.splitSpoken`, `Speaker.answer`, prompt in `Modes/Mode.swift`).
- **Spoken answers:** protocol `TextToSpeech`: ElevenLabs HTTP stream (`eleven_flash_v2_5`, `pcm_24000`) per sentence, started as soon as the first full sentence arrives, played through `PCMPlayer` (`Voice/Audio.swift`). Short version only: first sentence plus more while under 280 characters; markdown stripped. If ElevenLabs can't speak (402, no key, offline), the Mac voice (AVSpeechSynthesizer) speaks instead, with a one-time notice (0068a64). Speaker button in the panel mutes (`ttsEnabled`).
- **Settings → Voice:** ElevenLabs key (Keychain account `elevenlabs`, read once per launch) and Voice ID.
- Voice audio goes to ElevenLabs; screen content still only leaves through `ContextPacket.send()`.
- **Timings:** `log stream --predicate 'subsystem == "ie.dublinhacx.glance"'` shows the warm-up time, "transcribed by … in … s" and "release → first spoken audio … s" (time until the first audio buffer is queued; the speaker adds a few ms). Use `/usr/bin/log` in zsh (`log` is a shell builtin there). Keys, transcripts and screen text are never logged.

### Phase 2 check (owner)
- [x] `./scripts/selftest.sh` passes (STT/TTS request format, fallback order, sentence split, warm-up)
- [x] Warm-up runs at launch (log: 0.1 s)
- [ ] Owner: fresh launch → first point answers without the ~28 s hang
- [ ] Owner: add the ElevenLabs key in Settings, then 5 spoken questions transcribed correctly and answered aloud; read the release → first spoken audio times from the log
- [ ] Owner: speaker button mutes (also stops speech mid-answer)
- [ ] Owner: Wi-Fi off → hold ⌥Space → question shows "(on-device)" (macOS asks for Speech Recognition the first time); the answer then needs a provider that works offline, or shows the network error as text

### Phase 2 gotchas
- Xcode is installed and its license accepted (2026-10-03); `swift build` uses it. SwiftUI macros may now compile, but the code still uses the ObservableObject pattern.
- Recording starts on every key-down, so a quick tap shows the orange mic dot for a moment.
- The default voice is Sarah. Rachel is retired (HTTP 402 paid_plan_required). On a refusal Glance auto-picks a voice the account can use, otherwise it falls back to the Mac voice. See docs/notes/PHASE2-NOTES.md.
- `pcm_24000` on the free tier is UNVERIFIED; if TTS gets HTTP 4xx, try `pcm_22050` (change `PCMPlayer.sampleRate` too).

## Phase 3 (cross-app memory, branch `phase3`)
- **Recorder** (`Capture/MemoryRecorder.swift`): every `Config.captureIntervalSeconds` (3 s) it reads the frontmost app and focused window through Accessibility (`Capture/ActiveApp.swift`), runs `Exclusions.memorySkipReason`, then captures **only the frontmost window** with `SCContentFilter(desktopIndependentWindow:)` at 1× points. It re-checks exclusions after the capture, skips unchanged frames (128×72 grey diff, or same text as the last row), OCRs with Phase 1's `OCR.lines` at utility priority, and stores a row.
- **Timeline** (`Memory/Timeline.swift`): system SQLite 3.54 with FTS5 (checked at startup; memory turns off with a menu message if missing), `schema_version` table with ordered migrations, WAL, `secure_delete`, FTS5 `secure-delete`. File: `~/Library/Application Support/Glance/timeline.sqlite` (0600). Thumbnails are 320 px JPEGs (~2–15 kB) in the row.
- **Skipped before OCR or storage:** Glance, `Config.excludedApps`, any secure input, private or unreadable browser windows, `Config.blockedURLKeywords` (URL or title). `demo/mock-bank.html` is blocked by "bank".
- **Menu bar:** the eye icon is the capture indicator: `eye` = recording, `eye.slash` = paused/off, `eye.trianglebadge.exclamationmark` = not saving this window; the menu's first line says why (e.g. "Memory: not saving (password field)"). **Pause Memory / Resume Memory**, **Forget Last 10 Minutes**. Rolling deletion after `Config.retentionMinutes` runs about once a minute (also while paused) and at launch.
- **In a question:** on the first question of a selection, words from the question and the selected text search the timeline; matching lines from the newest row per window (≤6 windows) are redacted by `Redactor` inside `ContextPacket.withMemory` and sent only through `ContextPacket.send()`. The preview lists them under "From your last 15 min (redacted)". Memory stays redacted even when the user asks to reveal. No background cloud calls.
- **No Automation prompt:** URLs come from Accessibility, not AppleScript.
- **Selftest:** 40+ new checks (migrations, reopen, FTS search/escaping, retention, forget, exclusions incl. URL blocklist and secure field, change detection incl. caret blink vs scroll, thumbnail size, snippet redaction incl. reveal). Frame cost on a synthetic 1440×900 page with 40 lines: signature ~5 ms, OCR ~240 ms, thumbnail ~1.5 ms.

### Phase 3 check (owner, needs `./scripts/build-app.sh` from the `phase3` worktree)
- [ ] `./scripts/selftest.sh` passes (done by the agent: all passed)
- [ ] Browse 2 laptop pages (docs/DEMO.md), type `demo/budget-note.txt` into Notes, open the 3rd page, point at the specs and ask "How is this different from the earlier ones?" → the answer uses all three laptops and the €1,200 / 16GB budget; the preview shows the memory lines.
- [ ] Zero rows from an excluded app / password field: note the count, use 1Password or Keychain Access for 10 s, then click into a password field (e.g. a Safari login page) for 10 s, and count again:
  `sqlite3 ~/Library/Application\ Support/Glance/timeline.sqlite "select count(*), max(datetime(ts,'unixepoch','localtime')) from snapshots"`
  Recent rows: `sqlite3 ~/Library/Application\ Support/Glance/timeline.sqlite "select datetime(ts,'unixepoch','localtime'), app, window_title, url, length(text), length(thumb) from snapshots order by ts desc limit 10"`
- [ ] Pause → the icon becomes `eye.slash` and the count stops growing.
- [ ] Forget Last 15 Minutes → the count query returns 0 (and `select count(*) from snapshots_fts where snapshots_fts match 'laptop'` returns 0).
- [ ] A Safari private window adds zero rows (private detection is UNVERIFIED; see below).
- [ ] CPU: `top -pid $(pgrep -x Glance) -l 20 -s 3 | grep -E '^ *[0-9]+ +Glance'` while browsing, and while idle.

### Memory context and the "no MacBooks in memory" bug (owner report)
- **Root cause:** the MacBook pages *were* stored (rows 17:38–17:41 in the owner's timeline: MacBook Pro, Mac, Mac mini pages in Aside). Memory was attached only to a question that had a drag-box selection (`if let p = packet`); the owner asked by voice without pointing, so no memory was sent at all. The quiet 17:41:19–17:43:20 stretch was the same-text rule (one static page while talking), not skipped captures.
- **Now:** every question carries the recent activity (`Memory/MemoryContext.swift`): an activity log plus the de-duplicated text of every page in the last 10 min, budget `Config.memoryContextMaxChars` (60k), redacted as one block, shown in the preview ("🧠 Memory included: N pages from M apps, X characters"). A question with no selection sends just the question and the memory. Follow-ups refresh it when new pages were stored.
- **Skips are logged:** `log stream --predicate 'subsystem == "ie.dublinhacx.glance"' --info` shows "memory: not stored (reason) app … window …" once per change.
- **Unreadable browser URL:** now stored without a URL (owner decision), unless the window shows private markers or its title is blocked.
- **Not done:** an on-device model (FoundationModels) gist. The gist is extractive (prices, specs, chips); the full page text goes along anyway.

### Memory timing (owner request)
- Check every **1 s** (`Config.checkIntervalSeconds`): exclusions first, then capture + OCR of the focused window on every check; the unchanged-frame skip and the OCR backoff are gone.
- Snapshot every **3 s** (`Config.snapshotIntervalSeconds`): the most recent read is stored, unless its text is identical to the last row for the same window.
- Retention **10 min** (`Config.retentionMinutes`); the menu reads "Forget Last 10 Minutes".
- CPU: OCR costs ~0.2–0.27 s per check on a 1440×900 window (selftest prints it), so recording a text window uses roughly 20–30 % of one core continuously, up to ~50 % for 1920-pt windows. Idle cost is now the same as active cost, because nothing is skipped. Low Power Mode checks every 3rd second.

### Phase 3 review fixes (after three parallel reviews: privacy, CPU, correctness)
- Privacy: an incomplete browser AX walk counts as private (skipped); a browser page without a URL is skipped; the AX cache is keyed on the window element (a private and a normal window with the same title no longer share it); the captured window must match the AX focused window's frame; Pause/Forget can't be undone by a capture in flight; a question waiting on an old selection can't overwrite a new one; the memory folder is excluded from Time Machine.
- CPU: AX calls time out after 0.25 s (a hung app can't freeze Glance); a 256 px capture decides whether anything changed (no full capture or window enumeration on idle ticks); OCR capped at 1920 pt, no language correction; OCR backs off up to 30 s on windows whose pixels change but text doesn't (video, spinners); no capture while the display sleeps or the screen is locked; `synchronous=NORMAL`; trims run off the main thread.
- A19 (audit): the demo note's "Budget: €1,200 max" line was dropped (it shares no word with laptop specs). Short windows are now sent whole, the 50-row cap before de-duplication is gone, and "the earlier ones" questions fall back to recent windows. Selftest uses the real `demo/budget-note.txt` and fails without the fix.

### Phase 3 gotchas / open items
- **OCR warm-up flake (found and worked around):** a cold Vision load that runs after NaturalLanguage work (the Redactor's name tagger) fails with `CRImageReaderError error 1`, and OCR then stays empty for the whole process. Retrying in-process for 60 s doesn't help; only a relaunch does. The selftest now runs the warm-up first (as the app does at launch). The app logs the error, retries once, and shows "OCR unavailable — relaunch Glance" in the panel. Remaining risk: a redaction during the ~25 s cold load at the app's first launch after an update.
- Safari/Chrome private-window detection is UNVERIFIED: Glance looks for "Private Browsing", "Incognito", "InPrivate" in the window title and browser chrome. A browser window it can't read through Accessibility is treated as private (skipped). If Safari pages never get stored, the menu says "not saving (private window)"; tell the agent.
- Safari URL via `AXDocument`/`AXWebArea AXURL` is UNVERIFIED; without a URL, the blocklist still checks the window title.
- `IsSecureEventInputEnabled()` is system-wide: an app that leaves Secure Keyboard Entry on (Terminal's option, some password managers) pauses memory; the menu shows "not saving (password field)".
- This shell had no Accessibility or Screen Recording grant, so the live recorder wasn't run by the agent.

## Phase 4 (visible privacy + local-only, branch `phase4`)
- **Send/Cancel** (`UI/SendConfirm.swift`, reusable): `ContextPacket.send(..., confirm:)` waits for a tap only when the outgoing text has a high-risk tag ([CARD] [IBAN] [PPSN] [SSN] [PASSWORD] [PIN] [KEY] [SECRET] [TOKEN] [WALLET]) or is a reveal. Names, emails, phones and addresses go without a tap. The panel (card above the input) and Pip's bubble show e.g. "Hid 2 card numbers and 1 IBAN. Send?" with Send/Cancel; Return/Esc and a spoken "send"/"cancel" (hold ⌥Space) work too. Cancel sends nothing and shows "Cancelled. Nothing was sent." A packet's items ask once per conversation; a card typed in a follow-up asks again. Guide (Phase 5) passes its own `confirm:`, which is always awaited. `isScreen` packets are never revealed.
- **Redactor:** passwords are now `[PASSWORD]`, CVV/PIN values `[PIN]` (were [SECRET]/[ID]). A bare "Name" label tags the next OCR line as [NAME]; a label directly under a label (an "Account holder" heading above "Name") stays a label.
- **"I hid N" announcement removed (owner request):** nothing is spoken or shown in Pip's bubble; the panel preview still says "🔒 Hid N sensitive item(s)", and high-risk items still get the Send/Cancel card.
- **Answer speed (owner report: grok-4.6 on Azure, 33-60 s to first audio):** OpenAI-compatible requests send `reasoning_effort: "low"`. If a deployment rejects it (a 4xx naming "reasoning"), the request is resent without it, and that address+model is remembered in UserDefaults `reasoningUnsupported.<base>|<model>`. The memory budget dropped from 60k to 20k characters (both slow answers had hit the 60k cap). Timings in the log, sizes and times only: `ai: … request N kB, M image(s); headers … s, first reasoning … s (n events), first text … s, k text events over … s, total … s` and `answer: thinking … s until the first word (… s reading the screen and memory)`, `answer: Say line complete at … s`, `answer: total …`. Read them with `/usr/bin/log stream --predicate 'subsystem == "ie.dublinhacx.glance"' | grep -E "ai:|answer:|release"`.
- **Speech rule (owner):** Glance speaks only the answer's "Say:" line and Guide step instructions. Status, notices, errors, fallbacks and confirmations are silent, shown in the panel only. Pip's bubble shows only the answer's Say line, Guide steps and the Send/Cancel question; there's no filler beyond "Listening…" / "Thinking…". A selftest inventories speech call sites outside `Voice/` and Guide.
- **Local only:** menu "Local Only" (checkmark) and the Settings toggle, both UserDefaults `localOnly`. AI = `LocalOnlyProvider`: the Local provider (Ollama/LM Studio); if it fails before its first word, Apple's on-device model (`AppleOnDeviceProvider`, FoundationModels `SystemLanguageModel.default`, never Private Cloud Compute; text only; the prompt is cut to ~9k chars, keeping the question). Speech-to-text = Apple on-device only, voice = Mac voice. A green "Local only" badge shows in the panel header and under Pip.
- **Network gate** (`Network.swift`): every request goes through `Network.data(for:)` / `bytes(for:)` / `fire(_)`. While local only is on, any host but localhost/127.0.0.1/::1 throws `Network.Blocked` before a connection opens. The selftest scans every source file and fails on `URLSession`, `dataTask(`, `bytes(for:`, `NWConnection`, `WKWebView` etc. outside Network.swift.
- **Preview:** the image is full width, up to 220 pt tall; click it to open it full size.
- **Mock bank:** the selftest renders `demo/mock-bank.html`, OCRs it, and checks that card, IBAN, PPSN, email, password and name are all hidden and that the confirm appears.
- **Selftest:** 301 checks on phase4 (346 merged with phase5). Phase 4's checks are in `Phase4Tests.swift`. **Gotcha:** two selftests running at once (other worktrees) make Vision fail with `CRImageReaderError 1` (OCR warm-up / mock bank FAIL). Run them one at a time.

### Phase 4 check (owner, needs `./scripts/build-app.sh` from the `phase4` worktree)
- [x] `./scripts/selftest.sh` passes, including the network-gate inventory (agent)
- [ ] `open demo/mock-bank.html` → ⌥Space → drag over the whole page → ask "what is this?" → the preview shows black boxes, Pip/panel ask "Hid 1 card number, 1 IBAN, 1 PPS number, 1 password and N other items. Send?" → **Cancel** → "Cancelled. Nothing was sent." (no answer)
- [ ] Same again → **Send** → it answers
- [ ] A selection with only an email → sent with no tap and nothing spoken about it; the preview shows "🔒 Hid 1 sensitive item(s)"
- [ ] Menu → Local Only → badge on panel and Pip; ask a question → answer from Apple's on-device model (no Ollama); `nettop -p $(pgrep -x Glance)` shows no outbound traffic
## Phase 8 (visual polish, branch `phase8`)
- **Onboarding** (`UI/Onboarding.swift`): Pip-led, 3 steps: hello (point/talk/menu bar), the 3 permissions with a one-line why and live ✓, "what stays on your Mac". Shown on first run (`onboardingSeen` in UserDefaults) or while a permission is missing; "Permissions…" reopens it on the permissions step.
- **Error states** (`UI/Problem.swift`): `Problem.classify` turns the existing notice strings into designed cards (title, hint, fix button, "Details" with the raw text): no key, key for another address, offline, Azure deployment not ready, 401/403, 404, 429, 5xx, permission missing, Mac voice (info), ElevenLabs hiccup, OCR unavailable (Relaunch button). Memory paused / not saving (with the reason) / off shows as a chip under the status. Pip's bubble shows the friendly line; info notices (Mac voice) stay out of the bubble. ChatModel logic unchanged (one display-only `memoryState`).
- **Icon:** `AppIcon` renders an 8-bit penguin from Pip's own grid; `Glance --make-iconset <dir>` writes the PNGs and `build-app.sh` runs `iconutil` into `Contents/Resources/AppIcon.icns` (`CFBundleIconFile`). The menu-bar glyph is a 16×16 template penguin with a badge: none = recording, bars = paused, "!" = not saving, slash = off.
- **Panel:** answers render headings, fenced code (monospaced, horizontal scroll, Copy) and pipe tables (`UI/AnswerView.swift`); bullets; red Stop button; "Latest" scroll-to-bottom button; streaming only auto-scrolls while you're at the bottom; capsule follow-ups.
- **Pip visibility (owner request):** no idle corner Pip. `PetController.shouldShow` = Glance shown (`appear()`) or listening or speaking or `keepVisible()` (Phase 5 sets it to `chat.guide.active`). Hiding Glance calls `goHome()` then `disappear()`; `goHome()` now also calls `updateVisibility()`, so Pip leaves the screen when nothing keeps it. `show()`, `point()` and `say()` put Pip on screen. Reduce motion: appears at the corner, disappears in place.
- Not done here (owned by Phase 4): Settings regroup, the Local-only badge, the Send/Cancel confirm card, the bigger preview.

### Phase 8 check (owner, needs `./scripts/build-app.sh` from `glance-phase8`)
- [ ] `./scripts/selftest.sh` passes (all new checks pass; see the OCR note below)
- [ ] Onboarding: `defaults delete ie.dublinhacx.glance onboardingSeen`, relaunch → Pip's 3-step welcome
- [ ] Icon: `build/Glance.app` shows the penguin in Finder; the menu bar shows the penguin glyph; Pause Memory → bars badge
- [ ] Error states: remove the key (or Wi-Fi off) and ask → designed card with "Open Settings" / "Details"
- [ ] Pip: not on screen at launch; tap ⌥Space → centre → corner; hold → listening Pip; hide → gone; a spoken answer keeps Pip until it ends
- [ ] Panel: ask for a table or code ("show the specs as a table") → table and code block; scroll up mid-answer → "Latest" button
- OCR selftest note: the two OCR checks fail with `CRImageReaderError 1` while other worktrees run their selftests at the same time (main's binary failed the same way then). Run it alone.

## Tested build (owner-confirmed, 2026-10-03 18:15)
`main` = the combined build: Phase 2 voice, Phase 3 memory (memory on every question, the activity log, full recent context), Pip, and audit fixes A1–A19. 253 selftests pass. The owner confirmed "this version works well". Claude via Azure is pending the deployment's provisioningState = Succeeded.

## Phase 5 (Guide v1, branch `phase5`)
- "Show me how to …" (also "how do I", "walk me through", "guide me", "help me") starts Guide, checked before any other mode in `ChatModel.ask`. Target = front app, or the last non-Glance app when the panel is in front. Refused for excluded apps and secure input.
- Each step: `AXSnapshot.take` (menus → `MenuIndex`, depth 3, cap 400, Apple menu and `Config.guideSkippedMenus` dropped; focused window + sheets → up to 150 enabled on-screen controls; no AXValue, no secure fields; 0.25 s AX timeout, off the main thread) in parallel with `ContextPacket.captureScreen` (whole screen under the mouse, without Glance/excluded apps, OCR with word boxes, redacted, blacked out). The model sees M#/A#/O# lists (labels redacted in `withGuide`) and the image only if the provider takes images. Ids → elements/boxes stay on the Mac.
- Reply = one JSON step (`Mode.guide`). Pip moves as soon as `"ref":"X1"` streams in; `Locator.resolve` maps menu_path / M / A / O / label (never a guess) and `GuideHighlight.show` is the only code that touches Pip.
- Menu paths are followed locally by `MenuFollower` (AXMenuOpened/Closed; 400 ms grace when sliding across the bar; "That's Edit. Close it and click File"; after the last item it waits 2 s for a sheet/window). No model call per hop.
- next / why / skip / stop by voice, typing, the follow-up buttons, or a ⌥Space tap (= next during a session). Stop button ends the session. 90 s idle → Pip goes home, "next" resumes.
- Consent: Phase 4's `SendConfirm` (Send/Cancel) via `send(confirm:)`, once per session; it holds for the same app, ≤ the approved number of hidden items, 20 sends, 10 min. Cancel → "Nothing left your Mac." `isScreen` stops any reveal.
- Never clicks: `scripts/selftest.sh` fails on `AXUIElementPerformAction|kAXPressAction|CGEventPost|.post(tap`.
- Selftest: 46 Guide checks (`Modes/GuideTests.swift`). In this shell the 3 OCR checks fail with the known `CRImageReaderError 1` warm-up flake; main's build fails the same way here.

### Phase 5 check (owner; needs `./scripts/build-app.sh` from `~/Projects/glance-phase5`)
- [ ] Hour-0 pre-flight (Pages): the ring shows above the open File menu; `AXMenuOpened` fires for the Export To submenu (Pip moves to PDF…); the real labels match (Export To › PDF…, Next…, Export/Save); the consent card shows.
- [ ] Pages: "Show me how to export this as a PDF" → Send → Pip at File → open File: Pip moves to Export To, then PDF… with no "next" → Next… and Export via tap or "next" → Done, Pip goes home. 3 times in a row.
- [ ] TextEdit once (File › Export as PDF… › Save). Once with Cancel (nothing sent). Once on DeepSeek.

### Phase 5 hardening (integration, owner request "make sure the highlighted step by step works")
- Real labels, read from the app bundles (this shell has no Accessibility grant): Pages File › Export To › PDF…/Word…/Plain Text…/EPUB…, then the "Export Your Document" sheet (Next, Cancel), then a save panel. TextEdit File › Export as PDF… then a save panel. Matching ignores case and a trailing "…".
- Submenus: if Pages never posts AXMenuOpened for Export To's submenu, a 150 ms poll sees the submenu and moves Pip to PDF… (log: "submenu seen by poll").
- Mid-path: if File (or File › Export To) is already open when the step arrives, Pip goes straight to the next item.
- Esc stops Guide, except an Esc that closes a menu (menu open now or within 0.6 s).
- Speech: Guide speaks only step instructions (the step's say, "Hover Export To.", "Click PDF….", "That's Edit. Close it and click File."). "Let me look…", why, done, not-found and errors are shown in the bubble/panel only.
- Trace for one owner run: `/usr/bin/log stream --predicate 'subsystem == "ie.dublinhacx.glance" && eventMessage BEGINSWITH "guide:"' --info`. It logs snapshot counts and timing, step status/ref/role/label/path, the resolved target (menu/ax/ocr/not found) with its Cocoa rect, every AX menu note, each hop with its AX frame, poll hits, redirects, Esc and failures. No screen text.

### Phase 5 limits
- Phase 6 items (auto re-check, GuideWatcher, verdict, `next[]` local advance at runtime, 20 s nudge) are not built; `Config.guideAutoRecheck` is unused.
- The Window menu is skipped entirely (its document list).
- Pip's own window stays `.floating`, so an open submenu can cover Pip; the ring (popUpMenu+1) stays on top.

## Phase 6 (Guide v2, the automatic re-check, branch `phase6`)
- **Kill switch:** `Config.guideAutoRecheck` (UserDefaults, default on). `defaults write ie.dublinhacx.glance guideAutoRecheck -bool NO` = v1 (tap or "next"); read at each session start.
- **GuideWatcher** (`Capture/GuideWatcher.swift`): an AXObserver on the target app (window/sheet created, focused window, element destroyed, menu opened = strong; focused element, selection = weak) plus a session-only global `leftMouseDown` monitor (observe only). 600 ms debounce. Clicks while a MenuFollower menu is open are ignored. Clicks in Apple's open/save panel XPC service count as the app's.
- **Verdict** (`GuideVerdict`): click inside the target (4 pt slack) + any change → success; nothing changed → inconclusive; a click elsewhere in the app that opened a window/sheet/menu → spoken "That opened X. Press Esc, then click Y." and Pip re-points (nothing sent; the next Esc within 15 s doesn't stop Guide); a change without a click → inconclusive; other apps and stray clicks → ignored. Menu-path steps stay with MenuFollower, whose `.done` now counts as success.
- **After a success** (`Modes/GuideAuto.swift`): `last` → Done; else a fresh AX snapshot and `next[0]` is shown locally only when exactly one control has the exact normalized label (never "contains"; menu next → model); otherwise a model re-check with PROGRESS + `LAST STEP: click "X" — expected: Y`. Reply `check`: ok/wrong → show the step; not_yet → keep the highlight, silent. Re-checks: one per 3 s, 20 per session (then v1), on top of Phase 5's consent limits; Pip shows "Checking…" (not spoken).
- **Skip** (v2): noted in progress, then `next[0]` locally or the model. **20 s idle nudge** speaks the current step once (restarts on any activity). Why/Stop unchanged.
- Selftest: 35 v2 checks (`Modes/Phase6Tests.swift`): hit test, verdict, exact-match advance, rate limits, LAST STEP/check, kill switch, not_yet keeps the step. 427 total pass.

### Phase 6 check (owner; needs `./scripts/build-app.sh` from `~/Projects/glance-phase6`)
- [x] `./scripts/selftest.sh` passes (agent)
- [ ] Pages: "Show me how to export this as a PDF" → Send → open File › Export To › PDF… → Next… → Export with **no** "next" or ⌥Space; Done.
- [ ] On a button step, click Edit (or another menu/button) → spoken "That opened Edit. Press Esc, then click …"; Pip points back; Esc doesn't stop Guide.
- [ ] `defaults write ie.dublinhacx.glance guideAutoRecheck -bool NO`, relaunch → v1 (needs "next"); `defaults delete ie.dublinhacx.glance guideAutoRecheck` to undo.
- Trace: the Phase 5 `log stream` command; v2 lines are `guide: verdict …`, `guide: local advance …`, `guide: model re-check N`, `guide: re-check ok|wrong|not_yet`, `guide: idle nudge`.

## ⌥Space tap = type, Point = select (owner request, integration)
- A ⌥Space tap shows Pip and the panel with the cursor in the text field; no pointing overlay (`PanelController.tapAction`). The PointTool starts only from the panel's Point button. Hold = talk, tap during Guide = next, tap again = hide (unchanged). The menu's Show Glance acts like a tap.
- A question without a selection carries what's on screen now (`Capture/ScreenNow.swift`): the front non-Glance window's text from the newest memory row of that window if it is ≤ 3 s old, else a fresh `ContextPacket.capture` of that window (Glance and excluded apps filtered out; `Exclusions.memorySkipReason` skips excluded apps, password fields, private or blocked browser windows). Text only, cut to 6000 chars, redacted in `ContextPacket.withScreenNow`, and placed at the start of `memory` so the preview, Send/Cancel and the hid-N count cover it. Recent activity memory follows as before. Log: `screen now: …`.
- Selftest: 3 tap and 7 screen-now checks (in `Modes/Phase6Tests.swift`); 439 total pass.

## Pip-only by default + selection highlight clears (owner request, integration)
- **Surfaces** (`GlanceSurface` in `UI/Panel.swift`, pure): the chat panel is hidden by default. A ⌥Space tap shows Pip with a one-line field (cursor in it) and a Point button (`PetView.compactField`; Pip's window is a key-capable non-activating panel, so the front app stays active). Answers show in Pip's bubble (the Say line) with **Show more**, which toggles the panel (the panel's ✕ does the same; Pip stays). Hold = talk (Pip only). Tap during Guide = next. Tap again, or click Pip while its field is open = hide. Menu Show Glance opens the panel directly. Pip's window grew to 300×310 for the field.
- **Errors:** a failed question (`ChatModel.failed`) shows "Something went wrong." in Pip's bubble with Show more; the error card stays in the panel. Send/Cancel stays in the bubble.
- **Selection highlight** (PointTool overlay + Pip's pointing pose) clears when its answer has finished streaming and speaking (`chat.busy` false and Pip's speech estimate over), on the next question, on hide, or on Stop (`ChatModel.clearsHighlight`). Guide's ring is never touched.
- Selftest: 18 checks (surfaces, error bubble, highlight rules) in `Modes/Phase6Tests.swift`.
- **Hide chat** (owner request): while the panel is open, Pip's bubble link reads "Hide chat"; the panel header has a labelled "Hide chat" button; the menu has "Show Chat"/"Hide Chat" (`GlanceSurface.chatToggleTitle`). Esc in the panel (even in its text field) hides only the chat, unless Send/Cancel is open (`ChatPanel.escHidesChat`); it never stops an active Guide session (`Guide.escIsForChat`). Pip and its answer bubble stay. 6 selftests.

## Notes
- UI (Pip and the chat panel) architecture, Guide API, decisions, audit A13–A16 and gaps: [docs/notes/UI-NOTES.md](notes/UI-NOTES.md)
- Phase 3 (memory) background, root causes and open checks: [docs/notes/PHASE3-NOTES.md](notes/PHASE3-NOTES.md)
- Phase 2 (voice) architecture, decisions, ElevenLabs facts, audit A1–A12 and open items: [docs/notes/PHASE2-NOTES.md](notes/PHASE2-NOTES.md)
