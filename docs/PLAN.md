# Glance — phased build plan (Dublin HacX, today)

## Context
Glance is a Mac companion that already knows what you've been doing across every app. You point at anything on screen and speak, and it **Explains** the thing or **Guides** you step by step with highlights drawn on your screen. Its edge over Screenpipe: *"Screenpipe remembers your screen. Glance helps you act on it."*

Constraints: one-day build, a team of 2–4, Claude writes the code, Apple Silicon on macOS 27.2 beta, Swift 6.4 Command Line Tools (Xcode downloading as a backup). The rubric weights Technical 20, Impact 20, Innovation 15, Completeness 15, Design 10, Presentation 10, Judge's Preference 10, and judges score "what was built today".

Changes after the council review:
- Build a thin end-to-end version first, then widen it.
- Guide ships as one highlighted step first, with the re-check loop as an upgrade.
- One person carries both demos.
- Privacy is a visible moment.
- Backup video at about hour 4.
- Feature freeze at about 70% of the day.

## How we work
- **Phases are ordered so there's always a working demo.** Each phase ends with a **gate**: `selftest.sh` passes, manual checks, a screenshot to you, a commit, and your "go" before the next phase starts. Gates are short (about 5 min).
- **Later phases only add to earlier ones and never rebuild them.**
- **GitHub:** private repo `glance`. I ask before the first push, then push at each approved gate.
- **Keys** (Claude, DeepSeek, OpenAI, ElevenLabs) are typed into Glance's Settings and stored in Keychain. Claude never sees or commits them.
- **Skills used:** `claude-api` before writing the Claude provider, `security-and-hardening` for privacy, `run` for gate screenshots, `debug` when a gate fails.

## Designed for undecided choices (no rework later)
- **`Config.swift`:** one place for every default, overridable in Settings. It holds the hotkey (⌥Space), capture interval, retention (15 min), default provider and model, voice, TTS on/off and exclusion lists.
- **`AIProvider` protocol** with a capability flag `supportsImages`. Two implementations cover all four of your options:
  - `AnthropicProvider`: Claude, with vision
  - `OpenAICompatProvider` with presets:
    - **DeepSeek** (`api.deepseek.com`)
    - **OpenAI**
    - **Local**: Ollama/LM Studio at `localhost`, with a vision model such as `qwen2.5vl`
  - If the chosen model can't take images (e.g. a text-only DeepSeek model), Glance sends the OCR text of the selection and screen instead. Guide highlights still work because they snap to OCR boxes.
- **`SpeechToText` protocol** (ElevenLabs Scribe, Apple on-device fallback) and **`TextToSpeech` protocol** (ElevenLabs streamed, or off).
- **Prompts and redaction rules are data files** (`Resources/prompts/*.md`, `Resources/redaction.json`).
- **Modes register in one list** (Explain, Guide, Do).
- **SQLite has a `schema_version` table,** so schema changes migrate rather than reset.
- **`DECISIONS.md`** lists every open decision, its default and the exact setting or file that changes it.

## Architecture (SwiftPM app, one process)
```
glance/
  Package.swift  DECISIONS.md  README.md  .gitignore
  scripts/build-app.sh   swift build → Glance.app (Info.plist usage strings) → codesign "Glance Dev" → launch
  scripts/selftest.sh    runs `Glance --selftest` (assert-based, non-zero exit on failure)
  Sources/Glance/
    App.swift  Config.swift  SelfTest.swift
    UI/       Panel.swift · Settings.swift · Onboarding.swift
    Overlay/  OverlayWindow.swift · PointTool.swift · Highlight.swift
    AI/       AIProvider.swift · AnthropicProvider.swift · OpenAICompatProvider.swift · ContextPacket.swift
    Privacy/  Redactor.swift · Exclusions.swift · SendPreview.swift · Controls.swift
    Voice/    SpeechToText.swift · TextToSpeech.swift
    Capture/  Recorder.swift · OCR.swift · ActiveApp.swift
    Memory/   Timeline.swift
    Modes/    Mode.swift · Explain.swift · Guide.swift · Do.swift
  Resources/  prompts/*.md · redaction.json
```
**Hard rule:** the only code that sends screen content off the Mac is `ContextPacket.send()`, which always redacts and shows the preview first.

## Phases

### Phase 0 — Setup (≈30 min)
- Create `~/Projects/glance`, `git init`, and `gh repo create glance --private` (no push yet). Xcode downloads in the background (you've approved).
- **Your step (5 min, I'll walk you through it):** in Keychain Access, go to Certificate Assistant → Create a Certificate, name it "Glance Dev", type Code Signing. This makes permissions survive rebuilds without Xcode.
- Skeleton: menu-bar icon, ⌥Space opens and closes the panel, `Config.swift`, `--selftest`, `build-app.sh` and onboarding for Screen Recording, Accessibility and Microphone.

**Gate:** the app launches and the hotkey works. Permissions are granted and **still granted after a rebuild**. `selftest.sh` passes.

### Phase 1 — End-to-end slice (≈1.5 h): point → ask → answer
- PointTool: drag a box over any app, and the box stays highlighted.
- Screenshot plus selection go into a ContextPacket. A basic Redactor (card numbers, emails, API keys) and the exclusion list are applied, and the "what's being sent" preview is shown.
- Both AIProvider implementations with presets for Claude, DeepSeek, OpenAI and Local, chosen in Settings. Answers stream into the panel. Typed questions only.
- Explain mode, with follow-ups (Explain more / Example).

**Gate:**
- Point at a spec on a product page and get a correct, grounded answer from each provider you have keys for. Ollama is tested only if it's installed.
- A fake card number in the selection shows as `[CARD]` in the preview.
- Self-tests cover the redactor basics and the provider request format.

### Phase 2 — Voice (≈45 min)
- Hold ⌥Space to talk → ElevenLabs speech-to-text → question. The answer is spoken with streamed ElevenLabs text-to-speech, starting while the text is still arriving. There's a mute toggle.
- Falls back to Apple on-device speech when offline.

**Gate:** 5 spoken questions are transcribed correctly and answered aloud. Time to first spoken word is measured. The fallback works with the network off.
**→ Record backup video #1** (a point-and-speak Explain demo, ≈ hour 3–4).

### Phase 3 — Cross-app memory (≈1.25 h)
- Recorder: a ScreenCaptureKit snapshot every 3 s when the screen has changed → on-device Vision OCR → SQLite timeline (app, window title, URL, text, small thumbnail, timestamp).
- **Exclusions apply before OCR or storage:** excluded apps (password managers, Keychain, System Settings), a URL blocklist (banks, login and payment pages), private windows, and frames where a password field is focused.
- Capture indicator in the menu bar, pause, "forget last 15 min", and 15-minute rolling deletion.
- When you ask, recent timeline snippets that match the question go into the ContextPacket, redacted. Nothing from the timeline leaves the Mac otherwise. There's no background cloud summarizing.

**Gate:**
- Look at two products in Safari and a budget note in Notes. On a third product, *"How is this different from the earlier ones?"* correctly uses all three.
- An excluded app or password field adds zero rows. Forget deletes the rows (checked with a query). CPU stays reasonable.

### Phase 4 — Privacy hardening (≈45 min)
- Full `redaction.json` rules:
  - card numbers (Luhn) and IBAN (mod-97)
  - Irish PPSN
  - tokens and JWTs
  - 2FA codes and phone numbers
  - values next to "password" or "PIN" labels
- Redacted OCR boxes are **blacked out in the screenshot** sent.
- A packet with any redaction needs one tap to confirm.
- **Local-only switch:** forces the Local provider and Apple speech, and blocks all other network calls.

**Gate:**
- Self-tests: fake card, IBAN, PPSN and token strings are all redacted, with 0 false hits on normal product pages.
- The mock bank page preview shows blacked-out boxes.
- No outbound traffic in local-only mode.

### Phase 5 — Guide v1: one highlighted step (≈1 h)
- *"Show me how to export this as a PDF."* → the model names the next control → Glance finds it via its Accessibility element or OCR text match → draws a ring and arrow on it, with a one-line instruction (also spoken).
- When you click and ask "next", it takes a fresh screenshot and highlights the following step.

**Gate:** the chosen export flow is guided correctly, step by step, 3 times in a row.
**→ Record backup video #2** (shopping + Guide).

### Phase 6 — Guide v2: automatic re-check loop (≈1 h, upgrade)
- After each highlight, Glance watches for the screen to change, checks whether the right thing happened, and moves on to the next step or corrects you ("That opened Share. Close it and click File instead"). Adds the **Why?** and **Skip** buttons.

**Gate:** the flow completes hands-free, and a deliberate wrong click gets corrected.

### Phase 7 — Stretch (only if before the freeze)
- Do: "save this comparison". Shows a preview, then writes a Markdown table with source links after you approve.
- "Where was I?" recap.

### Feature freeze at ~70% of the day → Phase 8 — Polish & rehearse
- Visual polish, error states (no key, no network, no permission), and prompt tuning.
- Demo content: retailer pages, Notes file, the mock bank page with fake data, and the Guide app.
- Pitch, the Screenpipe and "is it safe?" one-liners, final backup videos.

**Gate:** the full demo runs 3 times in a row from a fresh launch, and the pitch is within the time limit.

**Cut order if behind:** Phase 7 → Phase 6 (Guide v1 still demos well) → Apple speech fallback. These are never cut: exclusions, redaction, the send preview and local-only mode.

## Demo — one person, one story (~2.5 min)
**Persona:** Aoife, a student, is buying her first laptop for college and has to learn new software for a class.
1. **Problem (15 s):** "Every AI makes you explain everything again. And unfamiliar apps are confusing."
2. **Shopping (60 s):**
   - Aoife browses two laptops and writes a budget note.
   - On a third, she points and asks aloud, *"How's this different from the earlier ones?"*. The spoken answer uses all three and her budget.
   - She points at a confusing spec and asks *"What does this mean for me?"*.
3. **Learning (45 s):** *"Show me how to export this as a PDF."* Highlights guide her step by step, including a correction after a wrong click if v2 is built.
4. **Privacy (20 s):** the mock bank page with a fake card. The preview shows it blacked out, and Glance says "I hid that." She turns on local-only mode, then "forget last 15 min".
5. **Close (10 s):** *"Screenpipe remembers your screen. Glance helps you act on it, privately."*

## Risks
- **macOS 27 beta / permissions:** Phase 0 proves signing and permissions first.
- **Empty Accessibility data in Chrome:** use Safari for the demo, with OCR text matching as the fallback.
- **Latency:** stream text and speech, draw the highlight immediately, downscale images.
- **Text-only providers (e.g. some DeepSeek models):** use the OCR-text fallback, and keep Claude as the default for demos.
- **Imperfect redaction:** said honestly in the pitch. Exclusions and local-only mode are the backstop.
