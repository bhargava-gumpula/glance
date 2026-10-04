import AppKit

/// Phase 5 selftests: assert-only, no network, AX or screen.
enum GuideTests {
    static func run(_ check: (Bool, String) -> Void) {
        // 1. Brace scanner
        let step = #"{"status":"step","ref":"A12","say":"Click Next."}"#
        check(Guide.objects(in: step) == [step], "guide: bare object")
        check(Guide.objects(in: "```json\n\(step)\n```") == [step], "guide: fenced object")
        check(Guide.objects(in: "{\n  \"status\": \"done\",\n  \"say\": \"All set.\"\n}").count == 1, "guide: pretty-printed object")
        let braces = #"{"status":"step","say":"Type {name} here } ok"}"#
        check(Guide.objects(in: braces) == [braces], "guide: braces inside a string")
        check(Guide.objects(in: step + #" {"status":"step","say":"Cli"#) == [step], "guide: truncated second object dropped")
        check(Guide.objects(in: "Sure! I can't help with that {oops").isEmpty, "guide: garbage → empty")
        check(GuideStep.parse("```json\n\(step)\n```")?.ref == "A12", "guide: GuideStep decodes the first object")
        check(GuideStep.parse(#"{"status":"done"}"#)?.status == "done", "guide: only status is required")
        check(GuideStep.recoveredSay(#"{"status":"step","say":"Click File","ref":"#) == "Click File", "guide: say recovered from a broken reply")

        // 2. Early ref
        check(Guide.earlyRef(in: #"{"status":"step","ref":"M1"#) == nil, "guide: unclosed ref → nil")
        check(Guide.earlyRef(in: #"{"status":"step","ref":"M15","#) == "M15", "guide: closed ref → M15")
        check(Guide.earlyRef(in: #"{"status":"step","ref":null,"#) == nil, "guide: null ref → nil")

        // 3. normalizeTitle
        let n = AX.normalizeTitle
        check(n("PDF...") == n("PDF…") && n("PDF…") == "pdf", "guide: PDF... == PDF… == pdf")
        check(n("Export To…") == "export to" && n("  Export   To ›") == "export to" && n("Name:") == "name", "guide: Export To… == export to")

        // 4. MenuIndex on a fake Pages tree
        typealias N = MenuIndex.Node
        let tree = [
            N(title: "Apple", children: [N(title: "About This Mac"), N(title: "Recent Items", children: [N(title: "Secret.pages")])]),
            N(title: "Pages", children: [N(title: "Settings…")]),
            N(title: "File", children: [
                N(title: "New"), N(title: "Open Recent", children: [N(title: "Diary.pages")]),
                N(title: "Export To", children: [N(title: "PDF…"), N(title: "Word…"), N(title: "EPUB…")]),
                N(title: "Print…"),
            ]),
            N(title: "Edit", children: [N(title: "Copy"), N(title: "Find", children: [N(title: "Find…")])]),
            N(title: "Window", children: [N(title: "Assignment.pages")]),
            N(title: "History", children: [N(title: "bank.ie")]),
        ]
        let menus = MenuIndex(bar: tree)
        check(menus.resolve(["File", "Export To", "PDF…"])?.display == "File > Export To > PDF…", "guide: full menu path resolves")
        check(menus.resolve(["file", "Export To...", "PDF..."]) != nil, "guide: menu path with ... resolves")
        check(menus.resolve(["File", "Export To", "Pages"]) == nil, "guide: missing path → nil")
        check(menus.resolve(["Print"])?.path == ["File", "Print…"], "guide: unique last title accepted")
        check(menus.resolve(["Nope", "EPUB..."])?.path == ["File", "Export To", "EPUB…"], "guide: wrong parents, unique last title")
        check(menus.resolve(["Find…"]) == nil, "guide: Find vs Find… is ambiguous → nil")
        let dup = MenuIndex(bar: [N(title: "Apple"), N(title: "File", children: [N(title: "Export…")]),
                                  N(title: "Edit", children: [N(title: "Export…")])])
        check(dup.resolve(["Export"]) == nil, "guide: ambiguous last title → nil")
        let all = menus.entries.map(\.display).joined(separator: "\n")
        check(!all.contains("About This Mac") && !all.contains("Secret") && !all.contains("Diary")
              && !all.contains("Open Recent") && !all.contains("Assignment") && !all.contains("bank"),
              "guide: Apple menu and skipped menus absent")
        check(menus.barItem("Apple") == nil && menus.bar.map(\.title) == ["Pages", "File", "Edit"], "guide: menu bar without Apple/skipped")

        // 5. localAdvance (exact normalized, never contains)
        check(Guide.localAdvance("Export", candidates: ["Export To", "Export Your Document"]) == nil, "guide: Export ≠ Export To")
        check(Guide.localAdvance("Export", candidates: ["Cancel", "Export…"]) == 1, "guide: single exact match")
        check(Guide.localAdvance("Export", candidates: ["Export", "Export…"]) == nil, "guide: two exact matches → nil")

        // 6. withGuide: redaction, secure fields, id order
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        let f = CGRect(x: 10, y: 10, width: 80, height: 24)
        check(AXSnapshot.keep(role: "AXTextField", subrole: "AXSecureTextField", enabled: true, frame: f, screens: screens) == nil
              && AXSnapshot.keep(role: "AXSecureTextField", subrole: nil, enabled: true, frame: f, screens: screens) == nil,
              "guide: secure field never listed")
        check(AXSnapshot.keep(role: "AXButton", subrole: nil, enabled: true, frame: f, screens: screens) == "button"
              && AXSnapshot.keep(role: "AXButton", subrole: nil, enabled: false, frame: f, screens: screens) == nil
              && AXSnapshot.keep(role: "AXButton", subrole: nil, enabled: true, frame: CGRect(x: 5000, y: 0, width: 80, height: 24), screens: screens) == nil
              && AXSnapshot.keep(role: "AXTextField", subrole: nil, enabled: true, frame: f, screens: screens) == nil,
              "guide: only enabled, on-screen kept roles")
        let empty = ContextPacket.Content(selectionImage: Data(), selectedText: "")
        var base = ContextPacket(appName: "Pages", redacted: empty, raw: empty, redactions: 0)
        base.lines = [OCR.Line(text: "Export Your Document", box: .zero)]
        let g = base.withGuide(progress: ["File › Export To › PDF… → done"], windowTitle: "Assignment", sheetTitle: nil,
                               menus: ["File > Export To > PDF…"], controls: [#"button "Share with aoife.k@example.ie""#])
        let block = g.guideBlock ?? ""
        check(block.contains("[EMAIL]") && !block.contains("aoife") && g.redactions == 1, "guide: labels redacted, redactions +1")
        let m = block.range(of: "M1 File")?.lowerBound, a = block.range(of: "A1 button")?.lowerBound,
            o = block.range(of: "O1 \"Export")?.lowerBound
        check(m != nil && a != nil && o != nil && m! < a! && a! < o!, "guide: ids in M, A, O order")
        check(block.hasPrefix("GOAL: {GOAL}\nPROGRESS: 1. File › Export To › PDF… → done"), "guide: goal and progress lead")
        let msg = g.firstMessage(empty, question: "Show me how to export this as a PDF", imagesAllowed: true)
        check(msg.text.hasPrefix("GOAL: Show me how to export this as a PDF") && msg.images.isEmpty, "guide: first message uses the guide block")

        // 7. Consent: Cancel sends nothing; Send sends the redacted packet. GuideSend runs on the main actor,
        // so the main run loop is spun instead of blocking it.
        func sendOnce(consent: Bool, question: String) -> GuideRecordingProvider {
            let recorder = GuideRecordingProvider()
            let box = ResultFlag()
            MainActor.assumeIsolated {
                GuideConsent.ask = { _ in consent }
                let stream = GuideSend.send(g, question: question, provider: recorder, needsConsent: true,
                                            preview: { _, _ in }, consented: { _ in })
                Task { _ = try? await stream.reduce("", +); box.done = true }
            }
            let deadline = Date().addingTimeInterval(5)
            while !box.done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            return recorder
        }
        check(!sendOnce(consent: false, question: "Show me how").called, "guide: consent Cancel → nothing sent")
        let sentText = sendOnce(consent: true, question: "Mail a@b.ie").lastText
        check(sentText.hasPrefix("GOAL: Mail [EMAIL]") && sentText.contains("[EMAIL]") && !sentText.contains("a@b.ie"),
              "guide: consent Send → redacted packet and goal sent")

        // send() clamp: a screen packet is never sent unredacted, even when reveal is asked for.
        var screenPacket = ContextPacket(appName: "Pages", redacted: .init(selectionImage: Data([0xFF]), selectedText: "Card [CARD]"),
                                         raw: .init(selectionImage: Data([0xFF]), selectedText: "Card 4242 4242 4242 4242"), redactions: 1)
        screenPacket.isScreen = true
        let clampRecorder = GuideRecordingProvider()
        let clampDone = ResultFlag()
        MainActor.assumeIsolated {
            let stream = ContextPacket.send(screenPacket, history: [], question: "Don't redact", reveal: true, announce: true,
                                            mode: .guide, provider: clampRecorder, showPreview: { _ in }, confirm: { _ in true })
            Task { _ = try? await stream.reduce("", +); clampDone.done = true }
        }
        let clampDeadline = Date().addingTimeInterval(5)
        while !clampDone.done && Date() < clampDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        check(clampRecorder.lastText.contains("[CARD]") && !clampRecorder.lastText.contains("4242"),
              "guide: send() clamp, reveal on a screen packet still sends redacted text")

        // 8. Coordinates
        check(PetGeometry.cocoaRect(fromAX: CGRect(x: 100, y: 50, width: 200, height: 40), primaryHeight: 900)
              == CGRect(x: 100, y: 810, width: 200, height: 40), "guide: AX → Cocoa")
        let v = Guide.visionRect(ocrBox: CGRect(x: 200, y: 100, width: 400, height: 40), imageSize: CGSize(width: 2880, height: 1800))
        let c = PetGeometry.cocoaRect(fromVision: v, in: CGRect(x: 0, y: 0, width: 1440, height: 900))
        check(abs(c.minX - 100) < 0.01 && abs(c.minY - 830) < 0.01 && abs(c.width - 200) < 0.01 && abs(c.height - 20) < 0.01,
              "guide: OCR box → Cocoa (100, 830, 200, 20)")
        let r2 = CGRect(x: -1920, y: -100, width: 1920, height: 1080)
        let v2 = Guide.visionRect(ocrBox: CGRect(x: 200, y: 100, width: 400, height: 40), imageSize: CGSize(width: 3840, height: 2160))
        check(r2.contains(PetGeometry.cocoaRect(fromVision: v2, in: r2)), "guide: OCR box on a negative-origin display stays inside it")
        let p = CGPoint(x: 321, y: 123)
        let back = Guide.axPoint(Guide.axPoint(p, h0: 900), h0: 900)
        check(back == p && Guide.axPoint(p, h0: 900) == CGPoint(x: 321, y: 777), "guide: Cocoa → AX → Cocoa round trip")
        let line = OCR.Line(text: "Click Export To now", box: CGRect(x: 0, y: 0, width: 190, height: 20), words: [
            .init(text: "Click", box: CGRect(x: 0, y: 0, width: 50, height: 20)),
            .init(text: "Export", box: CGRect(x: 55, y: 0, width: 60, height: 20)),
            .init(text: "To", box: CGRect(x: 120, y: 0, width: 20, height: 20)),
            .init(text: "now", box: CGRect(x: 145, y: 0, width: 45, height: 20)),
        ])
        check(Guide.ocrBox("Export To…", in: [line]) == CGRect(x: 55, y: 0, width: 85, height: 20), "guide: word boxes union inside a longer line")
        check(Guide.ocrBox("Save", in: [line]) == nil, "guide: no OCR guess")

        // 10. Entry
        check(Guide.isRequest("Show me how to export this as a PDF") && Guide.isRequest("how do I print this?")
              && !Guide.isRequest("How's this different from the earlier ones?") && !Guide.isRequest("Explain this to me"),
              "guide: isRequest")
        // Real transcripts: fillers first, punctuation anywhere, the request mid-sentence.
        let guideYes = [
            "Show me how to export this as a PDF.", "Okay, so show me how to export this as a PDF",
            "Hey Glance, can you show me how to export this as a PDF?", "Can you show me how to save this as a PDF",
            "Could you please walk me through exporting this?", "So, um, how do I export this as a PDF?",
            "How can I turn this into a PDF?", "I don't know how to export this to PDF.", "What's the way to print this?",
            "Help me export this as a PDF", "Can you help me save this document?", "Guide me through sharing this file.",
            "Where do I click to export?", "Where's the export button?", "Where is the share menu?",
            "Teach me how to make a PDF", "What do I click to save it?", "Which button exports it?",
            "Steps to export a PDF in Pages", "How do you export a PDF in Pages?", "OK. How would I add a page number?",
            "Pip, take me through printing this",
        ]
        let guideNo = [
            "How's this different from the earlier ones?", "How is this different from the MacBook?", "Explain this to me",
            "What is unified memory?", "What does this mean for me?", "Is 16 GB enough for college?", "Can you read this page?",
            "How much does it cost?", "How many cores does it have?", "Help me understand this spec",
            "How do I know if 16 GB is enough?", "How do I compare these laptops?", "Can you explain how this works?",
            "How do you pronounce this?", "Explain how to read this chart", "What's the best laptop for me?",
            "How does this compare to the ThinkPad?", "Which one should I buy?",
        ]
        let yesMiss = guideYes.filter { !Guide.isRequest($0) }, noHit = guideNo.filter { Guide.isRequest($0) }
        check(yesMiss.isEmpty, "guide: \(guideYes.count) Guide phrasings start Guide" + (yesMiss.isEmpty ? "" : " — missed: \(yesMiss)"))
        check(noHit.isEmpty, "guide: \(guideNo.count) Explain questions stay Explain" + (noHit.isEmpty ? "" : " — wrongly Guide: \(noHit)"))
        check(Guide.normalizeRequest("Okay, so, hey Glance — can you please show me how?") == "show me how", "guide: fillers and punctuation stripped")
        check(Guide.intent("Hey Glance, show me how to export") == "show me how" && Guide.intent("What is this?") == nil,
              "guide: intent names the matched rule")
        check(Guide.command("Next.") == .next && Guide.command("why?") == .why && Guide.command("never mind") == .stop
              && Guide.command("skip") == .skip && Guide.command("next to the button") == nil, "guide: local commands")

        // 11. Prompt carries the contract
        let sys = Mode.guide.system
        check(["\"status\"", "\"ref\"", "\"say\"", "\"label\"", "\"role\"", "\"menu_path\"", "\"why\"", "\"expect\"",
               "\"next\"", "\"last\"", "never act"].allSatisfy(sys.contains), "guide: system prompt has every contract key")
        check(Mode.all.map(\.name) == ["Explain", "Guide"] && Mode.guide.followUps.map(\.prompt).allSatisfy { Guide.command($0) != nil },
              "guide: mode registered; follow-ups are local commands")
    }
}

private final class ResultFlag: @unchecked Sendable { var done = false }

/// Records what would be sent, without any network.
private final class GuideRecordingProvider: AIProvider, @unchecked Sendable {
    var called = false
    var lastText = ""
    var name: String { "Test" }
    var supportsImages: Bool { false }
    func makeRequest(system: String, messages: [ChatMessage]) throws -> URLRequest {
        called = true
        lastText = messages.map(\.text).joined(separator: "\n")
        throw CancellationError()
    }
    func textDelta(fromEvent payload: String) throws -> String? { nil }
}
