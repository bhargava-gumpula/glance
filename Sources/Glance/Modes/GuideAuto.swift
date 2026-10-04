import AppKit
import ApplicationServices

/// Guide v2 (Phase 6): the automatic re-check. Local verdict first, the predicted `next[]` plan second,
/// the model only when those can't tell. Exists only while `Config.guideAutoRecheck` is on.
@MainActor
final class GuideAuto {
    private unowned let session: GuideSession
    private let pid: pid_t
    private var watcher: GuideWatcher?
    private var step: GuideStep?
    private var target: GuideTarget = .none
    private var limiter = RecheckLimiter()
    private var work: Task<Void, Never>?
    private var nudge: Task<Void, Never>?
    /// The correction says "Press Esc", so the next Esc soon after it must not stop Guide.
    var lastCorrection: Date?

    init(session: GuideSession, pid: pid_t) {
        self.session = session
        self.pid = pid
    }

    // MARK: Pure helpers (selftested)

    /// `next[0]` as a step of its own, if exactly one live control has its exact normalized label. Menu steps go to the model.
    nonisolated static func predicted(_ step: GuideStep, controls: [String]) -> (GuideStep, Int)? {
        guard let n = step.next?.first, let label = n.label, n.role != "menu",
              let i = Guide.localAdvance(label, candidates: controls) else { return nil }
        let rest = Array(step.next?.dropFirst() ?? [])
        let s = GuideStep(status: "step", ref: nil, say: n.say ?? "Click \(label).", label: label, role: n.role,
                          menu_path: nil, why: nil, expect: nil, next: rest, last: nil)
        return (s, i)
    }

    /// The `LAST STEP` line for a re-check.
    nonisolated static func lastStepLine(_ s: GuideStep) -> String {
        "click \"\(s.label ?? s.menu_path?.last ?? Guide.describe(s))\"" + (s.expect.map { " — expected: \($0)" } ?? "")
    }

    // MARK: Session hooks

    /// A step is on screen: watch what the user does with it.
    func arm(step s: GuideStep, target t: GuideTarget) {
        step = s
        target = t
        work?.cancel()
        if watcher == nil {
            let w = GuideWatcher(pid: pid, ignoreClicks: { [weak session] in session?.menuBusy ?? false }) { [weak self] o in
                self?.settled(o)
            }
            w.start()
            watcher = w
        }
        watcher?.reset()
        poke()
    }

    /// No step to watch (done, blocked, a model call in flight).
    func disarm() {
        step = nil
        work?.cancel()
        nudge?.cancel()
        watcher?.reset()
    }

    func stop() {
        disarm()
        watcher?.stop()
        watcher = nil
    }

    /// The 20 s nudge restarts on any progress.
    func poke() {
        nudge?.cancel()
        guard let say = step?.say, !say.isEmpty else { return }
        nudge = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Config.guideNudgeSeconds))
            guard let self, !Task.isCancelled, self.step != nil else { return }
            log.notice("guide: idle nudge")
            self.session.nudge(say)
        }
    }

    /// "not_yet" from a re-check: keep the old highlight and stay silent.
    func keepWaiting() -> Bool {
        guard let s = step else { return false }
        log.notice("guide: re-check says not yet; keeping the highlight")
        arm(step: s, target: target)
        return true
    }

    /// The current step worked (a verdict, or MenuFollower finished a non-last menu path).
    func stepSucceeded() {
        guard let s = step else { return }
        disarm()
        log.notice("guide: step succeeded locally")
        if s.last == true { session.finishLocally(s); return }
        advance(from: s, markDone: true)
    }

    /// Skip: progress is already noted; move to `next[0]` or ask the model.
    func skipped(_ s: GuideStep) {
        disarm()
        advance(from: s, markDone: false)
    }

    // MARK: Internals

    private func settled(_ o: GuideWatcher.Observation) {
        guard let s = step else { return }
        poke()
        let isMenu: Bool
        let rect: CGRect?
        switch target {
        case .menuPath: isMenu = true; rect = nil
        default: isMenu = false; rect = Self.axRect(target)
        }
        let hit = GuideVerdict.hit(click: o.click, clickPid: o.clickPid, pid: pid, target: rect)
        let verdict = GuideVerdict.judge(hit, strong: o.strong, weak: o.weak, opened: o.opened)
        let name: String
        switch verdict { case .success: name = "success"; case .wrong: name = "wrong"; case .inconclusive: name = "inconclusive"; case .ignore: name = "ignore" }
        log.notice("guide: verdict \(name, privacy: .public) (hit \(String(describing: hit), privacy: .public), menu step \(isMenu, privacy: .public))")
        guard !isMenu else { return } // MenuFollower owns menu steps, including wrong menus
        switch verdict {
        case .wrong(let opened):
            let label = s.label ?? Guide.describe(s)
            lastCorrection = Date()
            session.correct(GuideVerdict.correction(opened: opened, label: label), target: target)
            watcher?.reset()
        case .success: stepSucceeded()
        case .inconclusive: disarm(); recheck(s)
        case .ignore: break
        }
    }

    private func advance(from s: GuideStep, markDone: Bool) {
        work?.cancel()
        work = Task { [weak self] in
            guard let self else { return }
            let snap = await AXSnapshot.take(pid: self.pid, screens: AX.screenFrames)
            guard !Task.isCancelled else { return }
            if let (next, i) = Self.predicted(s, controls: snap.controls.map(\.label)),
               let f = AX.frame(of: snap.controls[i].element), AX.isUsable(f, screens: AX.screenFrames) {
                log.notice("guide: local advance → \(next.label ?? "-", privacy: .public)")
                self.session.advanceLocally(next, target: .ax(f), snap: snap, finished: markDone ? s : nil)
                return
            }
            log.notice("guide: plan ran out or didn't match; re-check")
            if markDone { self.session.noteDone(s) }
            self.recheck(s)
        }
    }

    private func recheck(_ s: GuideStep) {
        guard let wait = limiter.delay(now: Date()) else {
            log.notice("guide: re-check limit reached; back to tap or next")
            session.fallBackToV1()
            return
        }
        work?.cancel()
        work = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard let self, !Task.isCancelled else { return }
            self.limiter.record(now: Date())
            log.notice("guide: model re-check \(self.limiter.count, privacy: .public)")
            self.session.recheck(lastStep: Self.lastStepLine(s))
        }
    }

    /// The target in AX coordinates, for the hit test.
    private static func axRect(_ t: GuideTarget) -> CGRect? {
        let h0 = NSScreen.screens.first?.frame.height ?? 0
        switch t {
        case .ax(let f): return f
        case .ocr(let box, let region, let size):
            let c = PetGeometry.cocoaRect(fromVision: Guide.visionRect(ocrBox: box, imageSize: size), in: region)
            return PetGeometry.cocoaRect(fromAX: c, primaryHeight: h0) // the flip is its own inverse
        default: return nil
        }
    }
}
