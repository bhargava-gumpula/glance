# Task: Glance Phase 4 (privacy hardening)

**Owner:** the Phase 2 chat, after its 10-minute voice-hardening pass. Work on `main` in `~/Projects/glance`, as Phase 2 did.

## Already done (don't redo)
Phase 1 (e795343) already added:
- wide redaction: card/IBAN/PPSN/SSN/phones/addresses/wallets/keys/seed phrases/tokens/2FA/names/IPs
- OCR-box blackout
- the reveal override

Phase 3 (branch `phase3`) adds memory-snippet redaction, the URL blocklist and secure-field skipping.

## Read first
`docs/PLAN.md` Phase 4, `docs/HANDOFF.md`, `Sources/Glance/Privacy/*`, `AI/ContextPacket.swift`, `Voice/*`.

## Scope
1. **One-tap confirm:** if a packet triggered any redaction, or the user used reveal, the send waits on an explicit "Send" / "Cancel" in the panel. A packet with nothing redacted sends immediately, as today.
2. **Local-only mode:**
   - a Settings toggle plus a menu-bar item
   - when on: the AI provider is forced to the Local preset (localhost), speech-to-text to Apple on-device, and text-to-speech to off or Apple
   - **every** outbound request to a non-localhost host is refused in one central place, e.g. a single `Network.allow(url)` gate used by all providers and voice code
   - the panel shows a clear "Local only" badge
3. **Prove the network invariant:**
   - Add a selftest that inventories every `URLSession` use (grep-based or structural).
   - Assert they all route through the gate.
   - Assert the gate blocks non-localhost hosts in local-only mode.
4. **Mock bank check:** `demo/mock-bank.html` (fake data) must show every sensitive value blacked out in the preview image and tagged in the text.
5. **Audit fixes:** the orchestrator is running a privacy audit and may send confirmed findings. Fix them as part of this phase.

## Rules
- Don't relaunch the app without the owner's OK (they may be testing).
- Commit locally. The orchestrator coordinates pushes.
- Smallest complete change, `Config.swift` as the single source of defaults, update DECISIONS.md and HANDOFF.md.

## Phase 4 check (then STOP)
- selftest passes, including the network-gate inventory test.
- The owner confirms:
  - the mock bank preview is fully blacked out
  - Send/Cancel appears only when something was redacted
  - local-only mode makes no outbound traffic (`nettop -p $(pgrep -x Glance)` or Little Snitch)

## Report back
SendMessage **"Orchastrator"** with:
- commits
- each check item, pass/fail
- open issues and owner actions
