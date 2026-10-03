# Task: Glance UI polish (Phase 8 visuals) on branch `ui`

**Owner:** the UI chat. Work in `~/Projects/glance-ui` on branch `ui`.

## First
Merge local `main` into `ui`:
```bash
git -C ~/Projects/glance-ui merge main
```
This brings in Phase 2's voice and the "Say:" split (912158d). Then resolve the **semantic** fit:
- Pip's bubble shows the short spoken "Say:" line; the panel shows the full answer.
- Pip reacts to the listening, transcribing, thinking and speaking states from Phase 2.
- ⌥Space tap/hold semantics changed to key-up (Phase 2); make sure Pip's click and drag don't fight it.

## Scope
1. **Error states, designed rather than raw text:**
   - no API key
   - no network / provider error
   - permission missing (Screen Recording, Accessibility, Mic)
   - ElevenLabs failed, falling back to on-device
   - memory paused
   - "Local only" badge (the Phase 4 chat adds the mode; you design the badge)
2. **Onboarding:** a friendly first-run flow with Pip introducing itself, the 3 permissions and "what stays on your Mac" in plain language.
3. **Settings:** clean grouping (AI / Voice / Privacy / Memory), key fields clearly labelled, with a warning if a value looks like a key in a non-key field.
4. **App and menu-bar icon:** an 8-bit penguin icon (`.icns` built from PNGs with `iconutil`, wired in `build-app.sh`) and a template menu-bar glyph that still shows the recording, paused and not-saving states.
5. **The coordinate helper for Guide,** if not already done: AX top-left and Vision normalized rects → Cocoa screen rect, multi-display, with self-tests.

## Rules
- Visuals and wiring only. Don't change logic in ChatModel, ContextPacket, Redactor, the providers, Voice or Memory.
- Don't launch without the owner's OK.
- Commit on `ui`. No merge into `main`, no push without the owner's OK.

## Report back
SendMessage **"Orchastrator"** after each chunk with:
- commits
- screenshots, if the owner allowed a launch
- anything needing a merge or owner input
