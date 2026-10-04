# UI notes (Pip and the chat panel)

What a future UI chat needs that the code and commit history don't already say. The UI work happens in `~/Projects/glance-ui` on branch `ui`. `main` was fast-forwarded to `ui` at 5dcd29c.

## Owner decisions
- **The pet is Pip,** an 8-bit penguin. Rejected along the way: a one-eyed blob ("Iris"), axolotl, owl, fox, whale (looked like a dolphin), capybara and frog. The mockups were inline widgets in the UI chat, not files.
- **The chat panel stays as the fallback** until Pip is solid for the demo. Clicking Pip opens or closes it.
- **The panel opens to the left of Pip's top-right home,** so Pip and its bubble don't cover the panel header.
- **On every ⌥Space, Pip appears in the centre** of the active screen, then flies to the top-right.

## Architecture (`Sources/Glance/UI/`)
| File | Role |
|---|---|
| `Pet.swift` | `PetState`, the pure `PetState.derive(...)` state choice, `PetModel` (published layout, pointing, say, dismissed, talkUntil), `PetController` (its own borderless non-activating `NSPanel` of 300×260 holding a 120×90 sprite: flight, drag, Combine watchers), `PetView` (sprite plus bubble positioning, and the pure `bubbleText` / `spokenLine` / `lastReply`) and `RingWindow` (a click-through dashed box). |
| `PipSprite.swift` | The pixel art: a 20×15 grid of palette characters, left halves mirrored, with per-state overlays in `grid(_:tick:pointLeft:reduceMotion:)`. `PipSpriteView` draws it at 5 Hz with `TimelineView` + `Canvas`, using whole-point pixels and a 1-pt white halo. |
| `PetBubble.swift` | `PetBubbleView`: a square pixel border, a "PIP" tag and a pixel tail toward Pip. Its height is capped at 150 pt and it scrolls to the bottom while text streams. Inline markdown, and `displayText` keeps the last 600 characters. |
| `PetGeometry.swift` | Pure geometry: coordinate conversion, screen choice, `Layout` (window origin, sprite offset inside the window, pointLeft, bubbleBelow), `placement`, `home`, `center` and `isOffScreen`. |

Every file has its own `selfTest(check)`, called from `SelfTest.swift`. These are macro-free SwiftUI views (`ObservableObject`/`@Published`) because the Command Line Tools toolchain has no SwiftUI macro plugin.

## API for Guide (on `PanelController.pet`)
- `point(at: CGRect, ring: Bool = true)` takes **Cocoa global points** (origin at the bottom-left of the primary screen, y up), the same as PointTool's selection. Points, never pixels, so Retina needs nothing special. `ring` draws Pip's own dashed box; the PointTool selection already has one, so it is called with `ring: false`.
- `point(atAX:ring:)` takes AX/CG global coordinates (origin top-left of the primary screen, y down) and flips them with the primary screen's height.
- `point(atVision:in:ring:)` takes a Vision normalized rect (0–1, bottom-left origin) inside the capture region, given in Cocoa global points. If the region is in CG coordinates, convert it with `PetGeometry.cocoaRect(fromAX:)` first.
- `say(String)` shows text in the bubble until the user closes it or a newer answer arrives (it stores the latest reply id at the time).
- `goHome()` stops pointing, hides the ring, dismisses the current answer and flies to the home spot.
- `appear()` runs on every panel show: centre of the screen under the mouse, a 0.45 s pause, then a flight to the top-right home. A `point(at:)` during that pause cancels the flight.

## Placement rules
- Screen choice: the visible frame containing the target's centre, then the largest overlap, then the nearest screen.
- Pip sits right of the target (pointing left) if it fits, else left of it. If neither side fits, it sits centred above the target, or below if the top has no room.
- **The sprite is clamped onto the screen (A15), not the window.** The window is built around the sprite and may spill off-screen, which is harmless because it's transparent. The bubble goes above the sprite, or flips below when there's no room above (always the case at home).
- **Home** is the top-right of the active screen's `visibleFrame` (so below the menu bar), inset 16. It is recomputed on every `appear()`. Dragging Pip sets a new home until the next appear. If home's display goes away (`didChangeScreenParameters`), home resets.

## State and the Say:/answerRaw wiring
- **Priority:** listening > transcribing (shown as thinking) > talking > thinking (busy with no spoken line yet) > pointing > idle. See `PetState.derive`.
- **Wiring:** ChatModel publishes `answerRaw: (turn: UUID, raw: String)?`, set inside the stream loop in `ask()`. This is display-only; nothing else in ChatModel was changed for Pip.
- **Bubble:** Pip uses `Voice.splitSpoken` to show only the spoken "Say:" line, while the panel shows the full answer. With no "Say:" line, the bubble shows the answer itself.
- **Talking is estimated** (`speechSeconds`: 1 s + characters/14, capped at 280 characters), because Speaker doesn't publish playback state. Listening (barge-in) and mute cut it short; the Stop button doesn't.

## Accessibility and appearance
- **Reduce motion** (`NSWorkspace.accessibilityDisplayShouldReduceMotion`): no bob or flap and one pose per state; the blink is slowed. `appear()` skips the centre-to-corner flight.
- **Dark mode:** the sprite has a 60% white 1-pt halo so it shows on dark wallpapers. The bubble uses `.textBackgroundColor` and `.labelColor`, and its accent is #185FA5 in light mode and #73ABEB in dark.
- **Bubble accessibility:** one combined element labelled "Pip says: …", with a Close action.

## Audit fixes (AUDIT-1)
- **A13:** Pip was stuck pointing after a selection. Answer states now outrank pointing in `derive`.
- **A14:** talking followed the silent text instead of speech. It now follows the spoken line (estimated), and the bubble shows the Say line.
- **A15:** the window was clamped, so Pip pointed at the wrong spot near edges. The sprite is clamped instead, and the bubble flips below.
- **A16:** the last answer stayed in the bubble after hiding. `goHome()` now dismisses it.
- **Lows:** a Pip click hides through the same `PanelController.hide()` path as ⌥Space; home follows display changes; `say()` gives way to newer answers; going home resets the pointing side.

## UI-POLISH queue (on hold, `docs/tasks/UI-POLISH.md`)
Not started:
- designed error states
- Pip-led onboarding
- grouped Settings with a key-in-wrong-field warning
- an 8-bit penguin `.icns` and menu-bar glyph states

Item 5 (the coordinate helper) is done. An earlier panel idea that never reached code: a "Looking at" header with a selection thumbnail, a collapsible "what was sent" privacy card with redactions as black pills, capsule follow-up buttons and key-cap hints.

## Known gaps
- Pip has never been checked on screen by the UI chat: it has never launched the app. Clicks on a non-activating panel, drag versus tap, and bubble scroll versus tap-to-close all need a live check.
- Talking time is an estimate, and Stop doesn't cut it short.
- When the bubble is below Pip, its tail still points down.
- The pixel "…" for thinking sits top-right of the head, not centred.
- `displayText` can cut a `**bold**` pair, leaving a stray `**`.
- Running `./scripts/build-app.sh` from the UI chat was blocked by the session's permission check (it relaunches the running app), so the owner runs it.
