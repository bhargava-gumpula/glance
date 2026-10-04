# Task: Glance Phase 4 (visible privacy + local-only)

**Owner:** the "Phase 4" chat. **Running in parallel with the "Phase 5" chat (Guide)**, see Coordination below.

## Already done (don't redo)
- Wide redaction, OCR-line blackout, reveal only on explicit requests (A1)
- Keys bound to their host (A11), Address validation (A12)
- Memory on every question, redacted
- The single send path `ContextPacket.send()`

Read `docs/HANDOFF.md`, `docs/notes/PHASE2-NOTES.md`, `docs/notes/PHASE3-NOTES.md`, `docs/tasks/AUDIT-1.md` (A20), `Sources/Glance/AI/ContextPacket.swift`, `Privacy/*`, `Voice/*`, `UI/Panel.swift`, `UI/Settings.swift`.

## Scope
1. **Send/Cancel confirmation (owner-approved policy):**
   - Ask only when the outgoing packet contains a high-risk item or a reveal: `[CARD]`, `[IBAN]`, `[PPSN]`, `[SSN]`, `[PASSWORD]`/PIN/CVV, `[KEY]`, `[SECRET]` (seed phrases, private keys), `[WALLET]`.
   - Names, emails, phones and addresses are hidden **without** a tap.
   - The panel and Pip's bubble show "Hid 2 card numbers and 1 IBAN. Send?" with **Send** and **Cancel**.
   - Voice "send" / "cancel" also works.
   - Cancel sends nothing.
   - Make this a **reusable API**: Phase 5 needs the same confirm step for Guide's full-screen consent (see Coordination).
2. **"I hid N items":** when a send has any redactions, Pip and the voice say a fixed local line first, e.g. "I hid 3 sensitive items before sending". It's deterministic and not from the model.
3. **Local-only mode:** a menu-bar item plus a Settings toggle.
   - **AI:** the Local provider. If Ollama isn't reachable, use **Apple's on-device model (FoundationModels)** as the local AI. It's text-only, so it gets OCR text and memory text.
   - **Voice:** Apple on-device speech-to-text, and the Mac voice.
   - **Badge:** a clear "Local only" badge in the panel and on Pip.
4. **One network gate:**
   - Add `Network.swift`, with every URLSession request going through e.g. `Network.data(for:)` / `Network.bytes(for:)`.
   - It blocks every non-localhost host while local-only is on.
   - A selftest inventories every `URLSession`/`dataTask`/`bytes(for:)` use in `Sources` and fails if any bypasses the gate.
5. **Bigger preview:** the preview image is large enough to *see* the blacked-out card on stage, with click-to-enlarge.
6. **Mock bank check:** `demo/mock-bank.html` comes out with everything blacked out and tagged, and the confirm step appears.

## Coordination with Phase 5 (Guide)
- **Phase 4 owns:** `ContextPacket.send` (the signature and the confirm step), `Network.swift`, the provider and Voice networking, `Settings.swift`, the menu items.
- **Phase 5 owns:** the new `Guide/*` files, the AX snapshot and locator, Pip's pointing calls, and new capture helpers.
- **Shared:** `Panel.swift` and `SelfTest.swift`. Make small, additive edits only.
- **Agree the confirm API early:** message the "Phase 5" chat with its exact Swift signature as soon as it exists, so Guide's full-screen consent reuses it instead of building its own.
- Phase 5 will call `ContextPacket.send(...)` with a full-screen packet. Don't change the existing parameters without telling Phase 5.
- **Talk directly:** SendMessage the "Phase 5" chat about any change to a shared file or API.

## Rules
- Work in your own worktree: `git -C ~/Projects/glance worktree add ../glance-phase4 -b phase4`.
- Never edit `~/Projects/glance` (main) directly.
- No `build-app.sh`/launch without the owner's OK in your chat.
- Push the `phase4` branch freely. Never merge into `main`; the Orchastrator merges.
- Commit only your paths. Normal effort. Failing-first selftests.

## Phase 4 check (then STOP)
- selftest passes, including the network-gate inventory.
- Owner:
  - the bank page shows blackout + confirm, and Cancel sends nothing
  - "I hid N" is spoken
  - local-only gives no outbound traffic (`nettop -p $(pgrep -x Glance)`) and still answers via the on-device model

## Report back
SendMessage **"Orchastrator"** with:
- commits
- each check item, pass/fail
- whether the branch merges cleanly with `main` and with `phase5`
- open issues
