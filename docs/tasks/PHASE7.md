# Task: Glance Phase 7 (Do + "Where was I?"), stacked on Phase 3

**Owner:** the Phase 3 chat. Work in `~/Projects/glance-phase3` on branch `phase3`. These features need the timeline.

## First
Merge local `main` into `phase3` now:
```bash
git -C ~/Projects/glance-phase3 merge main
```
This brings in Phase 2's "Say:" short spoken answers (912158d). Rerun selftest. Merge `main` again whenever the orchestrator says it moved.

## Scope
1. **"Where was I?"**
   - The user asks it (voice or text, matched by intent, e.g. "where was I", "what was I doing").
   - Glance builds a recap from the last N minutes of the timeline: apps, titles/URLs and distinctive text, deduplicated.
   - The recap goes **only** through `ContextPacket.send()`, as redacted text with the preview, and the model answers with a short spoken "Say:" line plus a fuller on-screen list (goal, items seen, next step).
   - No background calls.
2. **Do: "Save this comparison"**
   - After a comparison answer, offer a "Save comparison" follow-up button, also triggered by voice ("save this").
   - The model returns a Markdown table plus source links (titles/URLs from the timeline).
   - Glance shows a **preview** in the panel, and only after the user clicks **Save** writes `~/Desktop/Glance Comparison <date>.md` and opens it.
   - Never write without approval. Never overwrite: add a numeric suffix.
3. Register both in the Modes registry (`Modes/Mode.swift`), so adding modes stays one file plus one line.
4. **Self-tests:** intent matching, recap building from fake rows (including redaction), comparison file naming and no-overwrite, and that no file is written without approval.

## Rules
- Don't run `build-app.sh` without the owner's OK.
- Don't merge into `main`. Push `phase3` when done.
- Don't start Phase 4. The Phase 2 chat owns it.

## Check (then STOP)
- selftest passes.
- The owner: after the 3-laptops flow, "Where was I?" gives a correct recap, and "Save this comparison" previews, then writes a correct file only after Save.

## Report back
SendMessage **"Orchastrator"** with:
- commits
- each check item, pass/fail
- whether the branch merges cleanly with `main`
- open issues
