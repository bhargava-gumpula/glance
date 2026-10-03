# Task: Glance Phase 2 (voice)

Phase 1's check passed (owner-approved 2026-10-03). Everything is pushed to the private repo.

## Read first, in order
1. `docs/HANDOFF.md`: current state, gotchas, owner requests
2. `docs/PLAN.md`: the Phase 2 section, plus "Designed for undecided choices"
3. `docs/research/phase2-voice.md`: ElevenLabs STT/TTS, mic capture, Apple fallback, with type-checked Swift snippets. Check every item marked UNVERIFIED before relying on it.
4. `DECISIONS.md`

## Scope
0. **First, a quick fix for the demo:** Vision OCR's first call after launch took ~28 s (see `docs/research/phase3-memory.md`), and Phase 1 runs OCR on every point. Run one warm-up OCR on a tiny image in the background at launch, so the first real question doesn't hang. Add a selftest or a timing log for it.
1. **Hold-to-talk:** hold ⌥Space to talk (the Hotkey already reports press and release), with AVAudioEngine capturing the mic → ElevenLabs Scribe speech-to-text → the question goes into the existing chat flow. A quick tap of ⌥Space keeps its current behaviour (toggle the panel and start pointing). Show a visible "listening" state in the panel.
2. **Spoken answers:** ElevenLabs streamed text-to-speech (low-latency model, e.g. `eleven_flash_v2_5`) reads a **short** version of the answer aloud and starts while the text is still arriving. Add a mute toggle in the panel, plus the voice ID in Settings (it goes in `Config`/DECISIONS.md).
3. **Fallback:** Apple on-device speech recognition when offline or ElevenLabs fails, and when local-only mode exists later. Silent text-only when text-to-speech fails.
4. **Protocols:** `SpeechToText` (ElevenLabs, Apple) and `TextToSpeech` (ElevenLabs, off), as in PLAN.md.

## Rules
- **The ElevenLabs key** is typed into Settings by the owner and stored in Keychain (reuse the existing key-storage pattern, read once per launch). Never ask for, see, log or commit keys.
- **Voice audio goes to ElevenLabs, screen content does not.** Screen content still only leaves through `ContextPacket.send()`.
- **No Xcode yet** (the owner is installing it), so SwiftUI macros (`@State`, `@Observable`) may not compile. Follow the panel's existing `ObservableObject`/`@Published` pattern.
- **Build with `./scripts/build-app.sh`** (signed "Glance Dev"). Add Phase 2 checks to `SelfTest.swift`: request format for STT/TTS, and the fallback selection logic.
- **Smallest complete change,** following the existing patterns in `Sources/Glance`.
- **Commits:** only `git add` your own paths. Pushing to `origin main` after the check passes is approved.

## Phase 2 check (then STOP; don't start Phase 3)
- The first point after a fresh launch answers without the 28 s hang (warm-up works).
- 5 spoken questions are transcribed correctly and answered aloud. Report the time from releasing the key to the first spoken word.
- Mute works. Network off → Apple speech fallback works, and the answer is shown as text.
- selftest passes.
- Update `docs/HANDOFF.md`, commit, push.

## When done, report back
SendMessage to the session named **"Glance Orchestrator"** (the lead chat) with:
- what changed
- the commit hash(es)
- each check item, pass/fail
- the measured latency
- open issues and owner actions

Do this even if you're blocked.
