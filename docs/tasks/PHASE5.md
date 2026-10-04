# Task: Glance Phase 5 + 6 (Guide)

Winner: **Design 1, AX-first**, with a total of **75** (38 + 37). Design 2 (OCR-first) totals **61** (28 + 33) and design 3 (vision-box) totals **53** (26 + 27). This brief keeps design 1's local menu hops and id-based contract and adds the best runner-up ideas: the predicted `next[]` plan (design 2/3), `reveal` and consent enforced inside `send()` (design 2), the brace scanner (design 2), word boxes (design 2), the kill switch (design 2), send-what-you-previewed (design 3) and `avoid(rect)` (design 3).

## Read first
- docs/PLAN.md (Phase 5, Phase 6, Demo, Risks), docs/HANDOFF.md, docs/DEMO.md, docs/research/phase3-memory.md, DECISIONS.md.
- `AI/ContextPacket.swift`: `send(...)` at about line 36 is the HARD-RULE single exit, and `capture(selection:on:appName:)` is at line 76.
- `Capture/OCR.swift`: `OCR.Line` boxes are image pixels with a top-left origin.
- On branch `ui`: `UI/Pet.swift` (`point(at:)`, `point(atAX:)`, `point(atVision:in:)`, `say`, `goHome`, and `RingWindow` `w.level = .floating` at line 180), `UI/Panel.swift` (`keyUp` at line 64, `toggle`, `show(pointing:)` at line 87, `let mode = Mode.explain` at line 135), and `Overlay/PointTool.swift:32` (`NSApp.activate()`).
- On branch `phase3`, not merged: `ActiveApp.secureInput()`, `Exclusions.memorySkipReason`, `MemoryRecorder.signature/frontWindowID`. Guide v1 does **not** depend on them (see Rules).

## Design
**v1 runtime flow (Phase 5).** The model gives one step at a time. A menu path counts as one step, and Glance follows its hops locally.
1. **Entry.** At the top of `ChatModel.ask`, before any other mode routing, check `Guide.isRequest(q)` with `(?i)^\s*(show me how|how do i|how can i|walk me through|guide me|help me)\b`, or `mode == .guide`. Guide is checked FIRST so a later Save-comparison mode (phase7-wip, "export this") can never take over the demo line. During a session, local commands are `why`, `skip`, `stop|cancel|never mind` and `next`; any other words go to `next(userText)`.
2. **Target app.** Use `NSWorkspace.frontmostApplication`. If that is Glance, use the last non-Glance app, tracked with `didActivateApplicationNotification`. Refuse if `Exclusions.isExcluded(app)` is true or secure input is on (`IsSecureEventInputEnabled()` or a focused AXSecureTextField). Pip then says why.
3. **In parallel** (`async let`):
   - `AXSnapshot.take(pid:)` uses a 0.25 s messaging timeout and bulk `AXUIElementCopyMultipleAttributeValues`. It builds the **MenuIndex** (skip the Apple menu; depth 3; cap 400; skip `Config.guideSkippedMenus`) and the **Controls** of the focused window and its sheets. Keep these roles: Button, PopUpButton, MenuButton, CheckBox, RadioButton, Tab, ComboBox, Link, DisclosureTriangle. Keep enabled elements with an on-screen frame only, cap 150, and mark the sheet's `AXDefaultButton` as `(default)`.
   - `ContextPacket.captureScreen(on:app:)` is the existing `capture(selection: screen.frame, …)` with word boxes on. It keeps `lines` and `region` local.
   - Ids are `M#`, `A#` and `O#` (OCR lines top to bottom, cap 250). The id → element/box table stays on the Mac.
   - Pip immediately says "Let me look at your screen…".
4. **Consent** (blocking, once per session). See the full-screen send path below. Cancel ends the session with "Nothing left your Mac."
5. **Ask.** Call `ContextPacket.send(packet, …, mode: .guide, confirm:)`.
   - While the reply streams, the regex `"ref"\s*:\s*"([AMO]\d+)"` moves Pip as soon as the id closes.
   - When the stream ends, `Guide.objects(in:)` parses the step (`first {…}` is the step).
6. **Resolve and point.** Call `Locator.resolve`, then `highlight(rect, step.say)`, then `speaker.begin/feed(step.say)/finish()`. Skip `Voice.splitSpoken`. The panel turn shows `Step n: File › Export To › PDF…` followed by `why`.
7. **MenuFollower** (`AXObserver` on the pid, main run loop, `.commonModes`, listening for `kAXMenuOpened`/`kAXMenuClosed`):
   - Parent title == `path[i]`: find `path[i+1]` among the open menu's children, point at it and say "Now Export To", or "Hover Export To" when it has a submenu.
   - A different top menu opens: debounce 400 ms, because sliding across the menu bar is fine. If it is still open, say "That's Edit. Close it and click File" and re-point at path[0].
   - The menu closes after the last hop: wait up to 2 s for `AXSheetCreated`, `AXWindowCreated` or `AXFocusedWindowChanged`. If one arrives, the step succeeded. If none does, say "Start at File again".
8. **Next.** Triggers are a ⌥Space tap during a session, which calls `guideNext()` and never `toggle()`, `PointTool` or `focusInput`, a spoken "next", or a Next follow-up. Next re-runs step 3 with no blocking consent while consent holds, then sends `PROGRESS`.
9. **End.** `status:"done"` or a local success on `last:true`: say, then `goHome()` after 3 s and remove the observers. Stop or Esc: `goHome()` now. After 90 s idle: go home; the session stays resumable.

**v2 runtime flow (Phase 6).** v2 adds an automatic re-check: local verdict first, model only when needed. Kill switch: `Config.guideAutoRecheck = true`. Set it to false and v2 falls back to v1 tap-to-next.
1. **GuideWatcher** uses the same AXObserver and listens for `AXFocusedWindowChanged`, `AXWindowCreated`, `AXSheetCreated`, `AXUIElementDestroyed`, `AXFocusedUIElementChanged` and `AXSelectedChildrenChanged`. It adds `NSEvent.addGlobalMonitorForEvents(.leftMouseDown)`, which only observes and only exists while a session is active, and a 600 ms debounce.
2. **Hit test:** `AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(pid), p.x, H0 − p.y)`, then walk up 3 parents and compare with `CFEqual` against the target. The result is `right`, `wrong` or `outside`.
3. **Local verdict:**
   - `right` plus the target destroyed, the sheet or window changed, or focus moved: the step succeeded.
   - `wrong`: say "That opened <AX title>. Press Esc, then click <label>" and re-point at the old target. Nothing is sent.
   - `O#` or unknown: inconclusive.
4. **Predicted plan** (grafted). After a success, try `step.next[0]` against a fresh AX snapshot. Advance locally only when **exactly one** enabled, visible candidate has an **exact normalized** label match. Never use "contains": "Export" must not match "Export To" or "Export Your Document".
5. **Model re-check** only when the step was inconclusive, the screen changed unexpectedly, or `next[]` ran out or failed to match.
   - Send `PROGRESS` + `LAST STEP … expected: <expect>`.
   - The reply's `check: ok|wrong|not_yet` means point at the new ref / say the fix and point at the corrective ref / keep the highlight and stay silent.
   - Limits: one send per 3 s and 20 per session. Pip shows "Checking…" while it waits.
6. **Why? / Skip / Stop** are `Mode.guide.followUps`, also available by voice. Why? speaks `step.why` with no send. Skip adds "user skipped X" to the progress and moves to `next[0]` or the model.
7. **20 s idle:** a local nudge re-says the current `say`.

## Target resolution + coordinate conversion
`Locator.resolve(step, snapshot, packet) -> Target?`, where Target is `.menuPath([MenuNode])`, `.ax(el)` or `.ocr(rect)`. Try in this order:
1. **`menu_path` non-empty or `M#`:** match the path against the live MenuIndex using `normalizeTitle` (lowercase; `...`→`…`; drop a trailing `…`, `›` or `:`; collapse whitespace). If the full path fails, accept a unique last-title match. Point at the `AXMenuBarItem` for path[0]; MenuFollower handles the rest. If path[0..i] is already open, start at hop i+1.
2. **`A#`:** read the frame live. On `kAXErrorInvalidUIElement`, re-walk and match by label plus role.
3. **`O#`:** use the line box. If the label is part of a longer line, use the union of its **word** boxes from `VNRecognizedText.boundingBox(for:)`, added to `OCR.lines(in:words:)`.
4. **null or unknown ref:** search a fresh AX walk (exact, then prefix), then MenuIndex last titles, then OCR lines (exact). Prefer the focused window or sheet. With no match: status not_found, Pip says the label with no ring. **Never point at a guess.**

A frame is valid only if it is at least 2×2 and intersects a screen. Items in a closed menu are never pointed at.

**Coordinates.** `H0 = NSScreen.screens[0].frame.height` (never `NSScreen.main`).
- **AX** (global, top-left of the primary display, y down) → Cocoa: `CGRect(x: ax.minX, y: H0 − ax.maxY, w, h)`. Use `pet.point(atAX:)` (PetGeometry, committed on ui at cec47eb) and do not reimplement it.
- **Cocoa point → AX hit-test point:** `(x, H0 − y)`.
- **OCR.Line box** (pixels, top-left, in a W×H image of region R): normalize to the Vision bottom-left form `n = (b.minX/W, 1 − b.maxY/H, b.width/W, b.height/H)`, then call `pet.point(atVision: n, in: R)`.
- **Raw Vision normalized boxes** (word boxes) need no flip: `pet.point(atVision: b, in: R)`.
- **Multi-display:** R is the capture screen's `frame` and can have a negative origin. H0 always comes from screens[0]. The model never returns pixels, so the 1568 px JPEG downscale never enters the math.

## Model contract (exact JSON)
`Mode.guide.system`:
- "You are Glance Guide. You teach; you never act."
- Choose ONE next physical action.
- Menu actions give the full `menu_path` using the titles exactly as listed.
- Use only listed ids (prefer A or M, O only if the control isn't in A or M). If the control isn't listed, ref is null and label is its visible text.
- No keyboard shortcut as the step (one may be mentioned in `why`).
- `[EMAIL]`/`[CARD]` are hidden values.
- Reply with exactly one JSON object, no prose, keys in this order.

User message (the `firstMessage` Guide block):
```
GOAL: Show me how to export this as a PDF.
PROGRESS: (none) | 1. File › Export To › PDF… → Export window opened
LAST STEP (v2 only): click "Next…" — expected: a save window asks for a name
APP: Pages — window "Assignment"; sheet: "Export Your Document"
MENUS:    M15 File > Export To > PDF…   (one per line)
CONTROLS: A12 button "Next…" (default)
SCREEN TEXT (OCR, top to bottom): O2 "Export Your Document"
```
The JPEG is attached only when `provider.supportsImages`.

Reply:
```json
{"status":"step","ref":"A12","say":"Click Next at the bottom right.","label":"Next…","role":"button","menu_path":[],
 "why":"Next takes you to where you name the PDF.","expect":"A save window asks for a name.",
 "next":[{"label":"Export","role":"button","say":"Click Export to save."}],"last":false,
 "check":"ok","observed":"Export sheet open on the PDF tab."}
```
Field rules:
- `status`: step | done | blocked | not_found.
- `ref`: `[AMO]\d+` or null.
- `say`: at most 14 words.
- `why`: at most 25 words.
- `expect`: at most 15 words.
- `next`: at most 3 items.
- `check` and `observed` are v2 only.
- `role`: menu | button | tab | popup | checkbox | field | link | other.

`GuideStep` is Decodable; only `status` is required.

Parse failure: recover a label from any `"say"` text, run it through Locator step 4, and otherwise show the raw text with no ring. There is no retry.

## Full-screen send path (only through `ContextPacket.send`)
- `send(..., confirm: (@MainActor (Preview) async -> Bool)? = nil)` is awaited **inside** the returned stream before `provider.stream`. Phase 4 has not landed, so Guide builds this minimal Send/Cancel card itself.
- Inside `send()`: `let reveal = reveal && !packet.isScreen`. Callers cannot bypass this.
- **Preview** (blocking on the first send): the blacked-out thumbnail plus "Guide will send your whole screen (redacted) to <provider>: image + N lines + M control names. Hid K." Text-only providers get "text only; the image stays on this Mac".
- What is sent is **exactly the previewed packet**, with no recapture after Send.
- **Consent** holds while all of these are true: same pid, same session, redactions ≤ the approved count, at most 20 sends, at most 10 min. Breaking any of them asks again. Every send still appends a non-blocking preview row.
- **Exclusions:** the SCK filter drops Glance and `Config.excludedApps`, as today. Refusal checks run before every capture and every v2 re-send.
- **Redaction:** `packet.withGuide(menus:controls:windowTitle:)` runs `Redactor.redact` on every label and title and adds the hits to `redactions`.
- **Blackout:** OCR hits are blacked out in the JPEG, as in Explain.
- **AX limits:** never read a field's `AXValue`, skip AXSecureTextField, skip the Apple menu, and skip the menus in `guideSkippedMenus`: Open Recent, History, Bookmarks, Recently Closed, Services, Profiles, People, and the Window menu's document list.
- **Local only:** AX handles, raw OCR, click points and boxes never leave the Mac. Logs record timings and counts only.
- **Never clicks:** no `AXUIElementPerformAction`, `kAXPressAction`, `CGEventPost` or `.post(tap:` anywhere.
- **Deferred until after the demo:** an app-only or window-level `SCContentFilter` that masks background private or blocked browser windows (record it in DECISIONS.md).

## Pip integration
- One function, `GuideHighlight.show(_ cocoaRect: CGRect?, say: String?)`, calls `pet.point(at:)`, `pet.say()` or `pet.goHome()`. Nothing else in Guide touches Pet. AX targets use `pet.point(atAX:)` and OCR targets use `pet.point(atVision:in:)`.
- **Required one-line change in Pet.swift:180:** `RingWindow` `w.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)`. The ring is already click-through.
- Pip's own window stays `.floating`, so it never covers a submenu.
- Add `PanelController.avoid(rect)` so the chat panel moves to the other side if it overlaps the target.

## Text-only provider path
DeepSeek gets the same M/A/O lists and no image, and picks ids. Accuracy is the same, because the resolution is local. Rehearse once on DeepSeek, because it is the only provider HANDOFF lists as verified. Use Claude only if its key passes a pre-flight test.

## Files
- **New:** `Capture/AX.swift` (about 180 lines): the shared `ax<T>`, `frame(of:)`, `AXSnapshot`, `MenuIndex`, `normalizeTitle`, `secureInputFocused()`.
- **New:** `Capture/AXWatch.swift` (about 120 lines): the AXObserver wrapper, MenuFollower, GuideWatcher.
- **New:** `Modes/Guide.swift` (about 250 lines): GuideSession, isRequest, command, prompt, GuideStep, `objects(in:)`, the ref regex, Locator, the verdict, `localAdvance`, GuideHighlight.
- **Changed:** `AI/ContextPacket.swift` (isScreen, lines, region, guide block, withGuide, captureScreen, `confirm:`, the reveal clamp).
- **Changed:** `Capture/OCR.swift` (`words:`).
- **Changed:** `Modes/Mode.swift` (`Mode.guide`; `all = [explain, guide]`).
- **Changed:** `UI/Panel.swift` (`@Published var mode`, routing, consent card, a tap means next during a session, `avoid`).
- **Changed:** `UI/Pet.swift` (the line-180 level change).
- **Changed:** `Config.swift`: guideSkippedMenus, guideMaxMenuItems 400, guideMaxControls 150, guideMaxOCRLines 250, axTimeout 0.25, guideDebounce 0.6, guideProviderTimeout 8, guideMaxSends 20, guideAutoRecheck true.
- **Changed:** `SelfTest.swift`, `scripts/selftest.sh`, DECISIONS.md, docs/HANDOFF.md, docs/DEMO.md.

## Self-tests (assert-only: no network, AX or screen)
1. **`Guide.objects`:** bare object, fenced object, pretty-printed object, braces inside a string, a truncated second object, garbage → empty.
2. **Ref regex:** `…"ref":"M1` (unclosed) → nil; `"ref":"M15",` → M15; `"ref":null` → nil.
3. **`normalizeTitle`:** "PDF..." == "PDF…" == "pdf"; "Export To…" == "export to".
4. **MenuIndex.resolve on a fake Pages tree:** the full path resolves, with `...` too; a missing path → nil; a unique last title is accepted; an ambiguous last title → nil. Skipped menus and the Apple menu are absent.
5. **`localAdvance`:** "Export" vs ["Export To", "Export Your Document"] → nil; a single exact match → that item; two exact matches → nil.
6. **withGuide:** "Share with aoife.k@example.ie" → `[EMAIL]` and redactions +1; a secure field is never listed; the ids come out in M, A, O order.
7. **send() clamp:** with a recording fake provider, `reveal:true` on a screen packet still sends redacted text; `confirm` returning false sends nothing.
8. **Coordinates:**
   - AX (100, 50, 200, 40) with H0 900 → (100, 810, 200, 40).
   - OCR (200, 100, 400, 40) in a 2880×1800 image, R = (0, 0, 1440, 900) → (100, 830, 200, 20).
   - The same box on R = (−1920, −100, 1920, 1080) in a 3840×2160 image lands inside R.
   - Cocoa→AX→Cocoa round trip.
9. **Verdict:** a hit on A12 or one of its children → right; A3 → wrong; another pid → outside.
10. **isRequest:** "Show me how to export this as a PDF" → true; "How's this different" → false.
11. **`Mode.guide.system`** contains every contract key.
12. **selftest.sh:** `! grep -rnE 'AXUIElementPerformAction|kAXPressAction|CGEventPost|\.post\(tap' Sources`.

## Phase 5 gate
- `swift build` and selftest are green.
- Owner check: in Pages, "Show me how to export this as a PDF" → consent card → Pip points at File. Opening File moves Pip to Export To, then PDF… with no "next". Then Next… and Export, both by tap or "next". Done, and Pip goes home.
- Repeat 3 times in a row.
- Repeat once on TextEdit (File › Export as PDF… › Save).
- Repeat once with Cancel → nothing sent.
- Repeat once on DeepSeek.

## Phase 6 gate
- The same flow runs hands-free (no taps after consent), 3 times in a row, using at most 3 model sends.
- Opening Edit instead of File is corrected locally in under 0.5 s.
- Clicking Share is corrected locally.
- Why? and Skip work.
- `guideAutoRecheck=false` falls back to v1 behaviour.

## Demo risks + mitigations
- **Hour-0 pre-flight**, through a temporary debug item "Point at File in 3 s". Check: the ring shows above the open File menu; an ⌥Space tap leaves the menu open; `AXMenuOpened` fires for the Export To submenu; the real Pages labels (Export To › PDF…, Next…, Export/Save); the save panel is visible over AX; SCK captures the open menu. Record the results in HANDOFF and fix DEMO.md.
- **If AXMenuOpened doesn't fire for submenus:** poll the expected item's frame every 150 ms behind one flag.
- **The ⌥Space hotkey is dead during menu tracking:** this is harmless, because menu hops are local and spoken "next" works too.
- **NSApp.activate closes the target app's menu:** Guide never calls PointTool, and the panel is nonactivating.
- **Slow, failed or offline model:** Pip says "Let me look…" immediately, the early ref regex moves Pip sooner, and an 8 s timeout lands on the error and Retry. Keep a phone hotspot and backup video #2 (record it right after the Phase 5 gate).
- **Wrong or invalid ref:** the Locator re-finds by label or answers not_found, never a guess.
- **Full-screen app or multiple displays:** demo windowed on one display.
- **Consent tap:** rehearse it as the privacy moment.
- **Hung AX calls:** 0.25 s timeout, snapshot taken off the main thread.

## Rules
- Branch decision: work in worktree `~/Projects/glance-guide` on branch `guide`, created **from `ui`**. Why `ui`:
  - `ui` already merged main (537039b).
  - `pet.point(atAX:)`, `point(atVision:in:)` and PetGeometry are committed there (cec47eb), so the pet methods can be called directly. `GuideHighlight` stays the one-function seam.
  - phase3 is not required. Guide carries its own secure-input check and the `ax<T>` helper in `Capture/AX.swift`. When phase3 merges, delete ActiveApp's private copy and add `memorySkipReason` to the refusal checks.
- Never click for the user.
- Every full-screen send goes through `ContextPacket.send`.
- Phase 5 cut first. Defer the speculative MenuIndex search, the signature fallback and app-only masking until both gates pass.
- No `scripts/build-app.sh` without the owner's OK. No merge to main or ui. No push.
- Commits are phase-scoped and the docs are updated.

## Report back
SendMessage to "Orchastrator" with:
- commit hashes and their messages;
- the selftest output and the Phase 5 and Phase 6 gate results (owner-run items marked pending);
- the hour-0 pre-flight results;
- open issues: phase3 integration, the Pet.swift line-180 change for the ui chat, label mismatches, and anything unverified.

## Coordination with Phase 4 (running in parallel)
- **Phase 4 owns:** `ContextPacket.send` (it's adding a reusable Send/Cancel confirm step), `Network.swift` (every request goes through it), the providers and Voice networking, Settings, the menu.
- **Reuse, don't build your own:**
  - **Consent:** Guide's full-screen consent should **reuse Phase 4's confirm API**. Ask the "Phase 4" chat for its signature; until it exists, put your consent behind one small function.
  - **Network:** don't add raw URLSession calls. Use the provider through `ContextPacket.send`.
- **Shared:** `Panel.swift` and `SelfTest.swift`. Make small, additive edits only. Message the "Phase 4" chat about any change to a shared file or API.
- **Pip:** Pip's API is already on main (`pet.point(at:)`, `point(atAX:)`, `point(atVision:in:)`, `say`, `goHome`), so you don't need the wrapper.
- **Base branch:** branch `phase5` from current `main` in your own worktree: `git -C ~/Projects/glance worktree add ../glance-phase5 -b phase5`.
- Never merge into `main`; the Orchastrator merges. Report to **"Orchastrator"**.
