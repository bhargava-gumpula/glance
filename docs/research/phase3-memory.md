# Phase 3 research: cross-app memory

Checked 2026-10-03 on Apple M5, macOS 27.2 beta, SDK 27.0 (Command Line Tools). Headers cited are under `$(xcrun --show-sdk-path)/System/Library/Frameworks`. "Compiled" means the snippet passed `swiftc -typecheck` (or was run) here. All snippets avoid SwiftUI macros. UNVERIFIED = not confirmed in docs, headers or a run.

## 1. ScreenCaptureKit single frame
Header: `ScreenCaptureKit.framework/Headers/SCScreenshotManager.h`. Docs: https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager

- `SCScreenshotManager.captureImage(contentFilter:configuration:)` returns a `CGImage` (async in Swift; the header has the completion-handler form, macOS 14+). The newer `captureScreenshot(contentFilter:configuration:)` (macOS 26+, `SCScreenshotConfiguration`, HDR-aware) is not needed.
- Exclude Glance's own windows with `SCContentFilter(display:excludingApplications:exceptingWindows:)` (SCStream.h, macOS 12.3+). Pass Glance's `SCRunningApplication` (match on `bundleIdentifier == "ie.dublinhacx.glance"`) plus excluded apps from `Config.excludedApps`. Phase 1's `ContextPacket` already does this; reuse it.
- Cost control: set `config.width/height` to the display's pixel size (or half it for recording; see OCR speed), `config.showsCursor = false`, `config.pixelFormat = kCVPixelFormatType_32BGRA`.
- Needs Screen Recording permission (already onboarded).

```swift
import ScreenCaptureKit

func grabFrame(excludingBundleIDs: Set<String>, scale: Double = 1.0) async throws -> CGImage {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let display = content.displays.first else { throw NSError(domain: "sck", code: 1) }
    let apps = content.applications.filter { excludingBundleIDs.contains($0.bundleIdentifier) }
    let filter = SCContentFilter(display: display, excludingApplications: apps, exceptingWindows: [])
    let cfg = SCStreamConfiguration()
    cfg.width = Int(Double(display.width) * scale); cfg.height = Int(Double(display.height) * scale)
    cfg.showsCursor = false
    return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
}
```
`SCShareableContent` enumeration is not free; cache it for a few seconds or refresh when the frontmost app changes. UNVERIFIED: `display.width` is points, not pixels, so `scale: 2` on Retina may be wanted for sharp OCR.

**Cheap change detection** (do this before OCR; OCR is the expensive step):
1. Downscale the frame to 64x36 grayscale (draw into a small `CGContext` with `.low` interpolation).
2. Keep the previous 2,304-byte signature; compute the mean absolute difference.
3. If the mean diff is below about 1.5/255 and the frontmost app plus window title are unchanged, skip. Otherwise OCR. Also force one OCR if nothing was stored for 60 s while the screen is changing slowly.
4. Optionally skip when the same text hash as the last row (hash the OCR text, not pixels).
Cost is well under 1 ms. Apple's `SCStream` with `SCStreamFrameInfo.status == .idle` flags unchanged frames, but a stream is heavier than one screenshot every 3 s, so it was not used. `CGDisplayCreateImage`-style APIs are deprecated, do not use.

```swift
import CoreGraphics

func signature(_ img: CGImage) -> [UInt8] {
    var px = [UInt8](repeating: 0, count: 64 * 36)
    px.withUnsafeMutableBytes { p in
        let c = CGContext(data: p.baseAddress, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 64,
                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        c.interpolationQuality = .low
        c.draw(img, in: CGRect(x: 0, y: 0, width: 64, height: 36))
    }
    return px
}
func changed(_ a: [UInt8], _ b: [UInt8], threshold: Double = 1.5) -> Bool {
    guard a.count == b.count else { return true }
    var sum = 0; for i in 0..<a.count { sum += abs(Int(a[i]) - Int(b[i])) }
    return Double(sum) / Double(a.count) > threshold
}
```
(Compiled.) Tune the threshold on real screens: a blinking caret should not trigger it, a scrolled page should.

## 2. Vision text recognition
Headers: `Vision.framework/Headers/VNRecognizeTextRequest.h`. Swift API in `Vision.swiftmodule/arm64e-apple-macos.swiftinterface`: `struct RecognizeTextRequest` (macOS 15+) with `recognitionLevel` (`.fast`/`.accurate`), `usesLanguageCorrection`, `recognitionLanguages`, `automaticallyDetectsLanguage`, `customWords`, `minimumTextHeightFraction`; result `[RecognizedTextObservation]`, each with `boundingBox: NormalizedRect` (normalized, origin bottom-left) and `topCandidates(_:)` -> `[RecognizedText]` (`.string`, `.confidence`). Perform with `try await request.perform(on: cgImage)`. The older `VNRecognizeTextRequest` + `VNImageRequestHandler` also exists. Use the Swift one: it is async, no macros, no Obj-C bridging.

```swift
import Vision

struct OCRLine { let text: String; let box: CGRect }   // box in pixels, origin top-left

func ocr(_ img: CGImage, accurate: Bool = true) async throws -> [OCRLine] {
    var req = RecognizeTextRequest()
    req.recognitionLevel = accurate ? .accurate : .fast
    req.usesLanguageCorrection = false              // faster; fine for search text
    let obs = try await req.perform(on: img)
    let W = Double(img.width), H = Double(img.height)
    return obs.compactMap { o in
        guard let t = o.topCandidates(1).first else { return nil }
        let b = o.boundingBox
        return OCRLine(text: t.string, box: CGRect(x: b.origin.x * W, y: (1 - b.origin.y - b.height) * H,
                                                  width: b.width * W, height: b.height * H))
    }
}
```
(Compiled; `NormalizedRect.origin/width/height` accessors confirmed by compile.)

**Measured speed** (my micro-benchmark: a synthetic 2880x1800 white page with 60 lines x ~230 characters of 22 pt system font, 172 observations; M5, `usesLanguageCorrection = false`):
- `.accurate`: **~230 ms per frame warm**, but the **very first call took 28 s** (one-off model compile/load, this beta). Run a dummy OCR at launch on a background task and show "warming up" before the first capture is used. Whether the cold cost repeats after a reboot or app relaunch is UNVERIFIED.
- `.fast`: ~125 ms warm, but it returned **0 lines** on that page (small text at this size). Do not use `.fast` for the timeline without testing real screens. UNVERIFIED why; the default `minimumTextHeightFraction` is a likely factor.
- Real screens (mixed UI, photos) will differ. Expect roughly 0.2-0.5 s per full frame; at one OCR per 3 s only when changed, that is single-digit percent CPU. Run OCR at utility QoS and skip while on battery saver (UNVERIFIED thresholds).

## 3. Frontmost app, window title, browser URL
All of this needs the Accessibility permission (already onboarded): https://developer.apple.com/documentation/applicationservices/axuielement_h

- **Frontmost app:** `NSWorkspace.shared.frontmostApplication` (`bundleIdentifier`, `processIdentifier`, `localizedName`). Subscribe to `NSWorkspace.didActivateApplicationNotification` instead of polling.
- **Window title / URL via AX** (no Automation prompt):
```swift
import ApplicationServices

func ax<T>(_ el: AXUIElement, _ attr: String) -> T? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v as? T : nil
}
func frontWindowInfo(pid: pid_t) -> (title: String?, url: String?) {
    let app = AXUIElementCreateApplication(pid)
    guard let win: AXUIElement = ax(app, kAXFocusedWindowAttribute) else { return (nil, nil) }
    let title: String? = ax(win, kAXTitleAttribute)
    let doc: String? = ax(win, kAXDocumentAttribute)          // AXDocument; a file:// or http URL string for document windows
    return (title, doc)
}
```
(Compiled.) `kAXDocumentAttribute` is "AXDocument" and `kAXURLAttribute` "AXURL" (`HIServices.framework/Headers/AXAttributeConstants.h`). Caveat: which attribute carries the page URL is **per app**:
  - Safari: UNVERIFIED whether the window exposes `AXDocument`. The URL field is a text field in the toolbar (find the `AXTextField` whose description is "Address and Search"; its `AXValue` is the URL, but it may show only the host when not editing). Test on the real browser.
  - Chrome/Chromium: UNVERIFIED. The content area is an `AXWebArea` that has `AXURL`; Chrome only builds its AX tree when an AT is detected. Set `AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)` (or `AXManualAccessibility`) on the Chrome app element; this is a known community workaround, UNVERIFIED on current Chrome.
- **AppleScript alternative** (reliable URL, needs the **Automation** permission per target app, shows a one-time prompt, needs `NSAppleEventsUsageDescription` in Info.plist; run through `NSAppleScript`):
  - Safari: `tell application "Safari" to return URL of current tab of front window`
  - Chrome: `tell application "Google Chrome" to return URL of active tab of front window`
  Cost: 20-100 ms per call and an extra permission. Recommendation: try AX `AXDocument`/`AXURL` first, fall back to AppleScript only for browsers where AX gives nothing, and only after the user opts in. Apply the URL blocklist before any OCR.
- **Private windows (UNVERIFIED, all of it):**
  - Chrome: AppleScript `mode of front window` returns `"incognito"` for incognito windows (widely documented in scripting dictionary, not rechecked).
  - Safari: no scripting property that I could confirm. A private window's AX title or toolbar shows "Private Browsing" in recent versions (UNVERIFIED); check `AXTitle` contains "Private". Safe default: if the browser is Safari or Chrome and private status cannot be determined, treat the frame as private (skip), and skip when the title contains "Private Browsing", "Incognito" or "InPrivate".

## 4. Secure (password) field focused
```swift
import ApplicationServices
func secureFieldFocused() -> Bool {
    let sys = AXUIElementCreateSystemWide()
    guard let el: AXUIElement = ax(sys, kAXFocusedUIElementAttribute) else { return false }
    let role: String? = ax(el, kAXRoleAttribute), sub: String? = ax(el, kAXSubroleAttribute)
    return sub == (kAXSecureTextFieldSubrole as String) || role == "AXSecureTextField"
}
```
(Compiled; reuses `ax` from section 3.) `kAXSecureTextFieldSubrole` = `"AXSecureTextField"` (`AXRoleConstants.h`). Works for native NSSecureTextField and Safari password inputs (UNVERIFIED for Safari; WebKit exposes them as secure text fields). Electron and Chrome need their AX tree enabled (see above), else the focused element may be missing.

**Belt and braces:** `IsSecureEventInputEnabled()` (Carbon HIToolbox, `import Carbon.HIToolbox`; compiled) is true whenever any app has secure input on (password fields in Terminal, browsers, Apple apps; password managers can leave it on). Treat `secureFieldFocused() || IsSecureEventInputEnabled()` as "skip this frame". It is a system-wide flag, so it errs on the side of skipping, which is what the plan wants. Check it twice: before the capture and right after, to avoid a race while the user tabs into a field.

## 5. SQLite from Swift
- `import SQLite3` works with the system libsqlite3 and needs no SwiftPM dependency or linker flag on macOS. System SQLite here is **3.54.0**, and `PRAGMA compile_options` shows **`ENABLE_FTS5`** (also FTS3/4). That is the CLI at `/usr/bin/sqlite3`; the library the app links is the same system dylib (UNVERIFIED but standard; confirm at startup with `SELECT sqlite_compileoption_used('ENABLE_FTS5')` and log if 0).
- Use WAL (`PRAGMA journal_mode=WAL`), `PRAGMA secure_delete=ON` (so "forget" actually overwrites pages), and `PRAGMA user_version` or a `schema_version` table. Store the DB under Application Support with `0600` permissions; thumbnails as small JPEG blobs (about 10-20 kB).
- Swift gotcha: `sqlite3_bind_text` needs `SQLITE_TRANSIENT`, which is not imported; define `let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)`.

```swift
import SQLite3
import Foundation

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class TimelineDB {
    private var db: OpaquePointer?
    init(path: String) throws {
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw NSError(domain: "db", code: 1) }
        try exec("PRAGMA journal_mode=WAL; PRAGMA secure_delete=ON;")
        try exec("""
        CREATE TABLE IF NOT EXISTS schema_version(version INTEGER NOT NULL);
        INSERT INTO schema_version SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM schema_version);
        CREATE TABLE IF NOT EXISTS snapshots(
          id INTEGER PRIMARY KEY, ts REAL NOT NULL, app TEXT NOT NULL, bundle_id TEXT,
          window_title TEXT, url TEXT, text TEXT NOT NULL, thumb BLOB);
        CREATE INDEX IF NOT EXISTS snapshots_ts ON snapshots(ts);
        CREATE VIRTUAL TABLE IF NOT EXISTS snapshots_fts USING fts5(
          text, window_title, url, content='snapshots', content_rowid='id');
        CREATE TRIGGER IF NOT EXISTS snap_ai AFTER INSERT ON snapshots BEGIN
          INSERT INTO snapshots_fts(rowid, text, window_title, url) VALUES (new.id, new.text, new.window_title, new.url); END;
        CREATE TRIGGER IF NOT EXISTS snap_ad AFTER DELETE ON snapshots BEGIN
          INSERT INTO snapshots_fts(snapshots_fts, rowid, text, window_title, url)
          VALUES ('delete', old.id, old.text, old.window_title, old.url); END;
        """)
    }
    func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "db", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]) }
    }
    func insert(ts: Double, app: String, bundleID: String?, title: String?, url: String?, text: String, thumb: Data?) throws {
        var st: OpaquePointer?
        defer { sqlite3_finalize(st) }
        guard sqlite3_prepare_v2(db, "INSERT INTO snapshots(ts,app,bundle_id,window_title,url,text,thumb) VALUES(?,?,?,?,?,?,?)", -1, &st, nil) == SQLITE_OK else { throw NSError(domain: "db", code: 3) }
        sqlite3_bind_double(st, 1, ts)
        func bind(_ i: Int32, _ s: String?) { if let s { sqlite3_bind_text(st, i, s, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(st, i) } }
        bind(2, app); bind(3, bundleID); bind(4, title); bind(5, url); bind(6, text)
        if let thumb { _ = thumb.withUnsafeBytes { sqlite3_bind_blob(st, 7, $0.baseAddress, Int32(thumb.count), SQLITE_TRANSIENT) } } else { sqlite3_bind_null(st, 7) }
        guard sqlite3_step(st) == SQLITE_DONE else { throw NSError(domain: "db", code: 4) }
    }
    func forget(since ts: Double) throws { try exec("DELETE FROM snapshots WHERE ts >= \(ts)") }   // numeric literal only
    func trim(olderThan ts: Double) throws { try exec("DELETE FROM snapshots WHERE ts < \(ts)") }
    func search(_ q: String, limit: Int = 5) throws -> [(Double, String, String)] {
        var st: OpaquePointer?; defer { sqlite3_finalize(st) }
        sqlite3_prepare_v2(db, "SELECT s.ts, s.app, snippet(snapshots_fts,0,'','',' … ',24) FROM snapshots_fts JOIN snapshots s ON s.id=snapshots_fts.rowid WHERE snapshots_fts MATCH ? ORDER BY rank LIMIT ?", -1, &st, nil)
        sqlite3_bind_text(st, 1, q, -1, SQLITE_TRANSIENT); sqlite3_bind_int(st, 2, Int32(limit))
        var out: [(Double, String, String)] = []
        while sqlite3_step(st) == SQLITE_ROW { out.append((sqlite3_column_double(st, 0), String(cString: sqlite3_column_text(st, 1)), String(cString: sqlite3_column_text(st, 2)))) }
        return out
    }
}
```
(Compiled, and the schema SQL was run in the `sqlite3` CLI.) Notes:
- Sanitize the FTS query: turn the user's question into OR-joined quoted tokens (`"token1" OR "token2"`), or `MATCH` throws on punctuation. Drop stop-words first.
- Add `PRAGMA user_version = N` migrations the way `schema_version` is used here: `if version < 2 { alter...; update schema_version }`.
- External-content FTS keeps text in one place; the delete trigger is what removes rows from the index when "forget" runs. Verify with `SELECT count(*) FROM snapshots_fts WHERE snapshots_fts MATCH 'x'` after forget (the Phase 3 gate asks for a query check).
- Rolling 15-minute deletion: `trim(olderThan: now - 900)` every minute, then `PRAGMA wal_checkpoint(TRUNCATE)` now and then so deleted data leaves the WAL file.

## 6. SwiftUI macros
None needed. ScreenCaptureKit, Vision, Accessibility, Carbon and SQLite3 are plain frameworks, all driven from AppKit and async code. The menu-bar capture indicator and pause toggle belong in the existing `NSStatusItem` menu.

## 7. Open items to test on the real machine
- 28 s first-call Vision latency: confirm after an app relaunch; add a warm-up.
- Real-screen OCR timing for `.accurate` vs `.fast`.
- Safari and Chrome AX URL exposure and private-window detection.
- Whether `IsSecureEventInputEnabled` is stuck on by a password manager and starves the recorder.
