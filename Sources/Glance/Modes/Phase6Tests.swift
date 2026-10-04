import Foundation

/// Phase 6 selftests (Guide v2): assert-only, no AX, screen or network.
enum Phase6Tests {
    static func run(_ check: (Bool, String) -> Void) {
        // 1. Hit test
        let target = CGRect(x: 100, y: 100, width: 80, height: 24)
        let H = GuideVerdict.hit
        check(H(CGPoint(x: 120, y: 110), 42, 42, target) == .right, "guide v2: click inside target → right")
        check(H(CGPoint(x: 98, y: 110), 42, 42, target) == .right, "guide v2: 4 pt slack → right")
        check(H(CGPoint(x: 400, y: 110), 42, 42, target) == .wrong, "guide v2: click elsewhere in the app → wrong")
        check(H(CGPoint(x: 120, y: 110), 7, 42, target) == .outside, "guide v2: click in another app → outside")
        check(H(nil, nil, 42, target) == .none, "guide v2: no click → none")
        check(H(CGPoint(x: 120, y: 110), 42, 42, nil) == .wrong, "guide v2: menu step, click in the app → wrong")

        // 2. Verdict
        let J = GuideVerdict.judge
        check(J(.right, true, false, nil) == .success, "guide v2: right + sheet → success")
        check(J(.right, false, true, nil) == .success, "guide v2: right + focus moved → success")
        check(J(.right, false, false, nil) == .inconclusive, "guide v2: right, nothing changed → inconclusive")
        check(J(.wrong, true, false, "Edit") == .wrong(opened: "Edit"), "guide v2: wrong + opened → correction")
        check(J(.wrong, false, true, nil) == .ignore, "guide v2: stray click that opened nothing → ignored")
        check(J(.none, true, false, nil) == .inconclusive, "guide v2: change without a click → inconclusive")
        check(J(.none, false, true, nil) == .ignore, "guide v2: focus noise without a click → ignored")
        check(J(.outside, true, true, nil) == .ignore, "guide v2: other app → ignored")
        check(GuideVerdict.correction(opened: "Find", label: "Next…") == "That opened Find. Press Esc, then click Next….",
              "guide v2: correction line")
        check(GuideVerdict.correction(opened: nil, label: "File") == "That's not it. Press Esc, then click File.",
              "guide v2: correction without a title")

        // 3. Predicted plan: exact match on next[0], exactly one candidate, never "contains"
        let step = GuideStep(status: "step", ref: "A3", say: "Click Next.", label: "Next…", role: "button",
                             next: [.init(label: "Export", role: "button", say: "Click Export to save."),
                                    .init(label: "Done", role: "button", say: nil)])
        let p = GuideAuto.predicted(step, controls: ["Cancel", "Export…", "Save"])
        check(p?.1 == 1 && p?.0.say == "Click Export to save." && p?.0.next?.map(\.label) == ["Done"],
              "guide v2: next[0] exact normalized match advances")
        check(GuideAuto.predicted(step, controls: ["Export To", "Export Your Document"]) == nil, "guide v2: Export ≠ Export To (no contains)")
        check(GuideAuto.predicted(step, controls: ["Export", "export…"]) == nil, "guide v2: two exact matches → model")
        check(GuideAuto.predicted(step, controls: []) == nil, "guide v2: no candidates → model")
        let menuNext = GuideStep(status: "step", next: [.init(label: "Export", role: "menu", say: nil)])
        check(GuideAuto.predicted(menuNext, controls: ["Export"]) == nil, "guide v2: menu next → model")
        check(GuideAuto.predicted(GuideStep(status: "step"), controls: ["Export"]) == nil, "guide v2: empty plan → model")
        check(GuideAuto.predicted(GuideStep(status: "step", next: [.init(label: "Save", role: "button", say: nil)]),
                                  controls: ["Save"])?.0.say == "Click Save.", "guide v2: missing say → Click <label>.")

        // 4. Re-check rate limits: one per 3 s, 20 per session
        var lim = RecheckLimiter()
        let t0 = Date()
        check(lim.delay(now: t0) == 0, "guide v2: first re-check immediate")
        lim.record(now: t0)
        check(abs((lim.delay(now: t0.addingTimeInterval(1)) ?? -1) - 2) < 0.001, "guide v2: second re-check waits to 3 s")
        check(lim.delay(now: t0.addingTimeInterval(5)) == 0, "guide v2: after 3 s no wait")
        for i in 1..<20 { lim.record(now: t0.addingTimeInterval(Double(i) * 3)) }
        check(lim.count == 20 && lim.delay(now: t0.addingTimeInterval(999)) == nil, "guide v2: 20 re-checks per session, then v1")

        // 5. Re-check message and reply
        check(GuideAuto.lastStepLine(GuideStep(status: "step", label: "Next…", expect: "A save window asks for a name."))
              == "click \"Next…\" — expected: A save window asks for a name.", "guide v2: LAST STEP line")
        let reply = GuideStep.parse(#"{"status":"step","ref":"A2","say":"Click Export.","check":"not_yet","observed":"Sheet still open."}"#)
        check(reply?.check == "not_yet" && reply?.observed == "Sheet still open.", "guide v2: check/observed decode")
        check(Mode.guide.system.contains("LAST STEP") && Mode.guide.system.contains("not_yet"), "guide v2: prompt explains check")

        // 5b. not_yet after a re-check restores the step (Phase 5 review): arm → pause → keepWaiting
        let (kept, cleared) = MainActor.assumeIsolated {
            let auto = GuideAuto(session: nil, pid: 0)
            auto.arm(step: GuideStep(status: "step", say: "Click Next."), target: .none)
            auto.pause()
            let kept = auto.paused && auto.keepWaiting() && !auto.paused
            auto.disarm()
            let cleared = !auto.keepWaiting()
            auto.stop()
            return (kept, cleared)
        }
        check(kept, "guide v2: not_yet after pause keeps the step")
        check(cleared, "guide v2: nothing to keep after disarm")

        // 6. Kill switch: on by default, a UserDefaults false turns v2 off
        let key = "guideAutoRecheck"
        let saved = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        check(Config.guideAutoRecheck, "guide v2: kill switch defaults on")
        UserDefaults.standard.set(false, forKey: key)
        check(!Config.guideAutoRecheck, "guide v2: kill switch off → v1")
        if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        check(Config.guideNudgeSeconds == 20 && Config.guideDebounce == 0.6, "guide v2: 20 s nudge, 600 ms debounce")
    }
}
