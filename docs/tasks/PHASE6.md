# Task: Glance Phase 6 (Guide v2, the automatic re-check)

**Owner:** the "Phase 6" chat. **Builds on Phase 5 (Guide v1), which the "Phase 5" chat is still hardening.**

## Read first
- `docs/tasks/PHASE5.md`: the full Guide design. **Its "v2 runtime flow (Phase 6)" section is your spec**: GuideWatcher, the hit test, the local verdict, the predicted `next[]` plan, the model re-check, Why/Skip, the idle nudge, the `Config.guideAutoRecheck` kill switch.
- `docs/HANDOFF.md` (Phase 5 section), and the Guide code on branch `integration` (`Sources/Glance/Guide/*`).

## Scope (from PHASE5.md, v2)
1. **GuideWatcher:**
   - the AXObserver events (window, sheet and focus changes, element destroyed, selection)
   - plus a session-only global `leftMouseDown` monitor, which only observes and never clicks, with a 600 ms debounce
2. **Hit test and local verdict:**
   - **right + something changed:** success, auto-advance
   - **wrong:** say "That opened X. Press Esc, then click Y" and re-point at the old target, with **nothing sent**
   - **unknown:** inconclusive
3. **Predicted plan:** advance locally on `step.next[0]` only when **exactly one** enabled, visible control has an **exact** normalized label match. Never use "contains".
4. **Model re-check** only when the step was inconclusive or the plan ran out. Rate limits: one per 3 s, at most 20 per session. Pip shows "Checking…" silently.
5. **Why? / Skip / Stop** buttons, also by voice. A 20 s idle nudge repeats the current step.
6. **Speech rule (owner):** speak only the short step instruction or correction. No filler.
7. **Kill switch:** `Config.guideAutoRecheck = true`. When false, Guide behaves exactly like v1 (tap or "next").

## Coordination with Phase 5 (important)
- **Phase 5 owns the existing `Guide/*` files** and is pushing hardening to `integration` right now: menu titles, the submenu poll fallback, Esc, mid-path start, logging.
- **Start by messaging "Phase 5"** to agree the hook points: where the session advances, how a watcher verdict is delivered, and which file holds session state. Put your work in **new files** (e.g. `Guide/GuideWatcher.swift`, `Guide/Verdict.swift`), with minimal agreed hooks.
- **Branch `phase6` from `integration` after** Phase 5's hardening push. Until then, design and write the new files against the agreed interface.
- **Worktree:** `git -C ~/Projects/glance worktree add ../glance-phase6 -b phase6 origin/integration`.
- `Panel.swift` and `SelfTest.swift` are shared, so keep edits small and additive. Phase 4 is also changing speech call sites on `integration`.
- **Never merge into `main` or `integration`;** the Orchastrator merges. No `build-app.sh` or launch without the owner's OK.
- Normal effort. Selftests for the verdict logic, exact-match advance, rate limits and the kill switch. Run the selftest alone (concurrent runs make Vision flaky).

## Phase 6 check (then STOP)
- selftest passes.
- **Owner, in Pages:**
  - the export flow completes **hands-free** after the first step
  - a deliberate wrong click (e.g. opening Edit) gets a spoken correction and Pip re-points
  - setting the kill switch off reverts to v1

## Report back
SendMessage **"Orchastrator"** with:
- commits
- each check item, pass/fail
- merge-cleanliness against `integration`
- open issues, plus a short owner test script
