# Phase 2 notes (voice, voice hardening, audit A1–A12)

Context for a future chat. HANDOFF.md ("Phase 2 (voice)") and DECISIONS.md cover the basics; this file
holds what they don't. No keys appear here or anywhere in the repo.

**Stale lines in HANDOFF "Phase 2":** "TTS failure → silent, text only" and "The default voice ID is the
premade Rachel" are out of date. Answers now always speak (Mac voice fallback), and the default is Sarah
with an auto-pick (see below).

## Voice architecture
| File | Role |
|---|---|
| `Hotkey.swift` | Carbon ⌥Space; passes each event's own timestamp (`GetEventTime`) to press/release |
| `UI/Panel.swift` `PanelController.keyDown/keyUp` | tap vs hold (`isTap`, 0.3 s by event time); a hold shows the panel without pointing |
| `UI/Panel.swift` `ChatModel` | `startRecording` / `askFromRecording` / `discardRecording`, `serial` (drops stale transcriptions), `listening` (barge-in + STT pre-connect), `muted`, `voiceNotice` (once per launch per text) |
| `Voice/Audio.swift` | `Recorder` (AVAudioEngine tap → 16 kHz mono Int16 WAV), `PCMPlayer` (streams 24 kHz PCM; `generation` drops audio from a stopped answer) |
| `Voice/Voice.swift` | `SpeechToText` / `TextToSpeech` protocols; `ElevenLabsSTT` (scribe_v2), `ElevenLabsTTS` (HTTP stream, flash v2.5, pcm_24000), `AppleSTT` (on-device only), `VoicePicker` (voice auto-pick), `Speaker` (Say-line splitting, sentence queue, budget), `VoiceError` (parses ElevenLabs `detail`), `STTTimings` (per-request timing log), `Voice.prewarmElevenLabs` |
| `Voice/MacVoice.swift` | `MacTTS` (AVSpeechSynthesizer, best English non-novelty voice), `FallbackTTS` (ElevenLabs → Mac voice) |
| `Capture/OCR.swift` `warmUp()` | one tiny OCR at launch so the first real question doesn't wait ~28 s |
| `Modes/Mode.swift` | system prompt asks for the "Say: …" line |

## Design decisions and why
- **Tap vs hold uses key-event timestamps**, not `Date()` when the main thread handles the event. `recorder.start()` (engine start) blocks the main thread for tens to hundreds of ms, which turned taps into holds. Recording starts on key-down so the first word isn't clipped. The hold timer is created before the engine starts, and a release that beats the timer still shows the panel.
- **Barge-in happens only once the press counts as a hold** (`listening` didSet), so a quick tap to hide or show the panel doesn't cut off speech.
- **The "Say:" split:** one LLM request. The model starts with `Say: <1-2 short sentences>`, then a blank line, then the full answer. Only the Say line is spoken, and it streams first, so speech starts before the long answer finishes. The full answer is shown. The marker is matched loosely (`**Say:**`, `_Say:_`, `> Say:`, `# Say:`, a newline after the marker). Without a marker, the start of the answer is spoken, capped at 280 characters. A sentence that doesn't fit ends speech, so a later sentence is never spoken without the one before it. History stores the raw text including the Say line, so the model keeps the format.
- **Voice auto-pick order** (`VoicePicker.candidates`):
  1. The account's usable voices from `GET /v2/voices` (premade first, then its own generated or cloned voices; never legacy or library).
  2. The 6 stock IDs: Sarah `EXAVITQu4vr4xnSDxMaL`, George `JBFqnCBsd6RMkjVDRZzb`, Will `bIHbv24MWmeRgasZH58o`, Roger `CwhRBWXzGAHq8TQ4Fs17`, Laura `FGY2WhTYpPnrIDTdsKH5`, Jessica `cgSgspJ2msm6clMCkdW9`.

  The first voice that returns 200 is saved as `elevenLabsVoiceID`. If none works, the voice is marked exhausted for the launch.
- **Mac voice fallback** (`FallbackTTS`): any ElevenLabs failure speaks that sentence with `MacTTS`.
  - Network errors (`URLError`) retry ElevenLabs on the next sentence.
  - Other errors (refused voice, bad key, credits) stick to the Mac voice until relaunch.
  - A one-time "Using Mac voice. (reason)" notice appears. Mute (`Voice.tts` → nil) silences both voices.
- **STT pre-connect:** when a hold is confirmed, `Voice.prewarmElevenLabs()` sends a HEAD request (no key, no audio) on the STT session. The 4–5 s first-request delay was DNS + TCP + TLS on a cold connection; later requests reuse it.
- **Cancellation:** a cancelled `AsyncThrowingStream` ends normally rather than throwing. So `ask()` checks `Task.isCancelled` after `await capture?.value`, inside the delta loop and after it. Otherwise an empty answer entered the history (Claude then returns 400), or `turns[index]` crashed after a new selection.
- **Recorder:** `start()` stops a running recording first; a second `installTap` raises an uncatchable NSException. It also checks mic authorization, because without it the engine records silence instead of failing.
- **PCMPlayer:** never calls `play()` after a failed `engine.start()` (another uncatchable exception), and stops the node on `AVAudioEngineConfigurationChange` so the next buffer restarts it.

## ElevenLabs facts learned (2026-10-03)
- **Rachel is retired.** `21m00Tcm4TlvDq8ikWAM` is a legacy voice and the API routes it to a library voice. On a free key, TTS returns **HTTP 402 `paid_plan_required`** ("Free users cannot use library voices via the API"), while STT with the same key works.
- **Default (stock) voices exist only on accounts created before March 2026**, and they expire 2026-12-31. A newer free account may have no stock voice at all.
- **Getting a usable voice on such an account:** create one in ElevenLabs Voice Design (it then counts as the account's own `generated` voice and the auto-pick finds it), or paste its ID into Settings → Voice ID.
- **Error body:** `{"detail":{"type","code","message","status","request_id"}}`. Older bodies have only `status`. `insufficient_credits` is also a 402 but isn't a voice problem.
- **`GET /v2/voices` needs the key's `voices_read` permission.** The app logs its status code and category counts.
- **Measured latency** in the owner's combined build, 17:41–17:56:
  - STT: ElevenLabs time 0.41–0.82 s on a reused connection; 0.59–1.01 s from key release to text.
  - Release → first spoken audio: 1.49–2.01 s, with one outlier of 10.6 s (probably a slow first LLM sentence).
  - Before the pre-connect, the first STT after launch took 4–5 s.

## The -1009 finding
"NSURLErrorDomain -1009 not connected" lines at 17:51–17:56 came from short-lived Glance processes (another chat's test runs inside a network-sandboxed agent shell), not from the owner's app. Check the pid in the log (`Glance[pid:…]`) against the running app (`pgrep -x Glance`) before debugging network errors.

## Audit 1 fixes (A1–A12, see docs/tasks/AUDIT-1.md)
| # | Fix |
|---|---|
| A1 | `Redactor.revealRegex` matches only explicit redaction requests ("don't redact", "unredact", "show the redacted …", "it's okay to see …"). Hidden/unhide/unmask/stop hiding no longer match |
| A2 | `ChatModel.previewedFor` + `needsPreview`: a new "Sending to …" preview when the provider name or its image setting changes |
| A3 | `guard !Task.isCancelled` after `await capture?.value` (in e84cb89) |
| A4 | The name tagger skips ranges containing `Redactor.productWords` (retina, liquid, xdr, neural, …) |
| A5 | Card regex made lazy (`{12,18}?`), so expiry/CVC digits on the same line don't break Luhn |
| A6 | `Redactor.redactLines`: the line under a bare Password/PIN/CVV/CVC/security code label becomes `[SECRET]`. `ContextPacket.capture` now redacts lines with their neighbours |
| A7 | `redactCodes`: `[CODE]` for 4–8 digit (or `G-123456`, `123-456`) tokens on a line that mentions code/passcode/OTP/verification |
| A8 | SECRET label may sit inside an env identifier (`OPENAI_API_KEY=`, `AWS_SECRET_ACCESS_KEY=`); `whsec_` prefix added. "Max tokens: 16000" is kept |
| A9 | handle/login/log-in/ship to/bill to/recipient need `:` or `=` |
| A10 | `redactLines` keeps an `inPEM` flag from BEGIN to END PRIVATE KEY |
| A11 | `keyHost.<id>` in UserDefaults; `Providers.current` refuses when the host differs (`Config.keyHostMismatch`). Old keys adopt their current host on first use; saving a key records its host; Remove clears it |
| A12 | `Config.validBaseURL` (http/https + host) and `Config.validVoiceID` checked in `SettingsModel.save`; the prefs file was checked, no key was stored there |

## Not fixed (low, owner said leave)
- `FallbackTTS`'s sticky flag lasts until relaunch, even if the key is fixed in Settings.
- Focus doesn't return to the previous app when a tap hides the panel (Phase 1 behaviour).
- `AppleSTT` has no timeout (a missing recognizer callback would leave "Transcribing…" up).
- The STT timeout is 6 s idle with a 12 s total; long recordings could hit it.
- A tap briefly shows the orange mic dot (recording starts on key-down by design).
- The OCR warm-up selftest is flaky under heavy machine load (Vision returned no text after a 46 s cold start). Phase 3 has a retry for it.

## Owner test checklist
1. Fresh launch → point and ask: no ~28 s wait (log: "OCR warm-up took …").
2. Hold ⌥Space and ask 5 questions: each is transcribed and the short version is spoken (ElevenLabs, or the Mac voice with the notice).
3. Speaker button mutes, including mid-answer. A quick ⌥Space tap doesn't stop speech.
4. Wi-Fi off → hold ⌥Space: the question shows "(on-device)".
5. Spec block with "Liquid Retina": not blacked out. Mock bank: card with expiry/CVC and the password field are hidden.
6. "How do I show hidden columns?" doesn't show ⚠️ Not redacted.
7. Switch provider mid-conversation, then Explain more: a new preview appears.
8. Settings: a key pasted into Address is refused with a message.

## Log commands
```bash
/usr/bin/log stream --predicate 'subsystem == "ie.dublinhacx.glance"'
/usr/bin/log show --last 30m --predicate 'subsystem == "ie.dublinhacx.glance"' --style compact
```
Lines to look for: "voice: STT … connect … ElevenLabs … total", "transcribed by", "release → first spoken audio", "GET /v2/voices HTTP … N voices: …", "switched to ElevenLabs voice", "Mac voice is …", "using the Mac voice". In zsh, `log` is a builtin, so use `/usr/bin/log`.

## Other gotchas
- `scripts/build-app.sh` relaunches the app. Ask the owner first when they're testing.
- Selftests that need the MainActor (Speaker) spin `RunLoop.main.run(until:)` inside `MainActor.assumeIsolated`.
- In Swift 6, `NSLock.lock()` can't be called from async code; use `withLock` or a sync helper.
- The old HANDOFF note "Xcode license not accepted → `DEVELOPER_DIR=/Library/Developer/CommandLineTools`" is resolved. It was the cause of both `swift build` and `git` failing with exit 69.
