# Handoff

## Status
**Phase 0 (setup): done, gate passed (2026-10-03).**
**Phase 1 (end-to-end slice): done, gate passed (2026-10-03)** with DeepSeek (via the owner's Azure AI Foundry endpoint, text-only). Claude and OpenAI weren't tested (no keys yet); Ollama isn't installed. **Phase 2 (voice): built, owner checks pending (2026-10-03).** See "Phase 2" below.

Phase 1 adds:
- ⌥Space shows the panel and starts the **PointTool**: drag a box over any app (Esc skips). The box stays highlighted and lets clicks through. The "Point" button in the panel starts a new one.
- **ContextPacket** (`AI/ContextPacket.swift`): ScreenCaptureKit capture of **only the selected region** (owner request; the rest of the screen is never captured or sent), without Glance or excluded apps → on-device Vision OCR → **Redactor** → any OCR line with a hit is blacked out in the images. `ContextPacket.send()` is the only path that sends screen content; it redacts the question too and puts the "Sending to …" preview (thumbnail + text + "Hid N sensitive items") in the thread before the request starts.
- Pointing at an excluded app (`Config.excludedApps`) is refused. Excluded apps are also cut out of every screenshot.
- **AIProvider** + `AnthropicProvider` (raw HTTP/SSE, `claude-opus-5-5`, effort low, server-side refusal fallback on) + `OpenAICompatProvider` (DeepSeek, OpenAI, Local). Text-only models get OCR text instead of images.
- **Settings…** in the menu (⌘,): provider, model, address, "can see images", API key → Keychain (service `ie.dublinhacx.glance`, account = provider id).
- Panel is a **chat thread**: streamed answers, Explain more / Example follow-ups, Stop, typed follow-up questions. A new selection starts a new thread.

## After the Phase 1 gate (owner request, 2026-10-03)
- Redaction widened (see DECISIONS.md "Redaction rules"). 80 selftest checks, including product-page lines that must stay untouched.
- Override: if the question explicitly asks to see hidden data ("don't redact", "unredact", "show the hidden email", "it's okay to see my address"), `send()` uses the raw copy kept in memory. It stays on until the next selection, and the preview shows ⚠️ Not redacted. Excluded apps stay excluded.
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
- **Spoken answers:** protocol `TextToSpeech`: ElevenLabs HTTP stream (`eleven_flash_v2_5`, `pcm_24000`) per sentence, started as soon as the first full sentence arrives, played through `PCMPlayer` (`Voice/Audio.swift`). Short version only: first sentence plus more while under 280 characters; markdown stripped. TTS failure → silent, text only. Speaker button in the panel mutes (`ttsEnabled`).
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
- The default voice ID is the premade "Rachel"; if the account doesn't have it, TTS fails silently (log shows HTTP 4xx). Paste another voice ID in Settings.
- `pcm_24000` on the free tier is UNVERIFIED; if TTS gets HTTP 4xx, try `pcm_22050` (change `PCMPlayer.sampleRate` too).
