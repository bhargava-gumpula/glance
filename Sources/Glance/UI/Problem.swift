import AppKit
import SwiftUI

/// A designed error or status message: a friendly title, a one-line hint, an optional fix button and the raw
/// text behind a "Details" disclosure. Built from the notice strings ChatModel already produces, so no logic changes.
struct Problem: Equatable {
    enum Severity { case info, warning, error }
    enum Action: Equatable { case settings, permissions, relaunch, retryLater }

    var severity: Severity
    var symbol: String
    var title: String
    var hint: String
    var action: Action? = nil
    var detail: String? = nil

    /// What Pip says in its bubble: short, no raw provider text.
    var bubble: String { hint.isEmpty ? title : "\(title). \(hint)" }

    /// Classifies a notice turn's text.
    static func classify(_ raw: String) -> Problem {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        func has(_ words: String...) -> Bool { words.contains { lower.contains($0) } }

        if text.hasPrefix(ChatModel.macVoiceNotice) {
            let reason = text.dropFirst(ChatModel.macVoiceNotice.count).trimmingCharacters(in: CharacterSet(charactersIn: " ()"))
            return Problem(severity: .info, symbol: "speaker.wave.2", title: "Using Mac voice",
                           hint: "ElevenLabs couldn't speak, so your Mac reads the answers instead.",
                           detail: reason.isEmpty ? nil : reason)
        }
        // Phase 4 notices (Send/Cancel confirm, Local-only network gate, on-device model).
        if has("nothing was sent") {
            return Problem(severity: .info, symbol: "xmark.circle", title: "Cancelled", hint: "Nothing was sent.")
        }
        if has("local only is on") {
            return Problem(severity: .info, symbol: "lock.laptopcomputer", title: "Kept on this Mac",
                           hint: "Local only is on, so Glance didn't contact the internet. Turn it off in Settings to use a cloud AI.",
                           action: .settings, detail: text)
        }
        if has("on-device model isn't available") {
            return Problem(severity: .warning, symbol: "cpu", title: "No on-device model",
                           hint: "Local only needs Ollama or Apple's on-device model. Start Ollama, or turn off Local only in Settings.",
                           action: .settings, detail: text)
        }
        if has("ocr unavailable") {
            return Problem(severity: .error, symbol: "text.viewfinder", title: "Can't read text on screen",
                           hint: "macOS's text reader didn't start. Relaunch Glance to fix it.", action: .relaunch)
        }
        if has("api key in glance settings") {
            let provider = text.components(separatedBy: "Add your ").last?.components(separatedBy: " API key").first ?? "provider"
            return Problem(severity: .warning, symbol: "key", title: "Add an API key",
                           hint: "Pip needs your \(provider) key before it can answer. It's stored in your Keychain.",
                           action: .settings)
        }
        if has("api key was saved for") {
            return Problem(severity: .warning, symbol: "key", title: "Key is for a different address",
                           hint: "Re-enter the key in Settings to use it with this address.", action: .settings, detail: text)
        }
        if has("offline", "not connected to the internet", "network connection was lost", "could not be found",
               "timed out", "cannot connect to host", "could not connect to the server",
               "error -1009", "error -1001", "error -1003", "error -1004", "error -1005", "error -1020") {
            return Problem(severity: .warning, symbol: "wifi.slash", title: "You're offline",
                           hint: "Pip can't reach the AI right now. Memory keeps working on this Mac.", action: .retryLater, detail: text)
        }
        if has("microphone", "check permissions", "speech recognition for glance", "couldn't read the screen", "screen recording") {
            let what = has("microphone") ? "the microphone" : has("speech recognition") ? "Speech Recognition" : "Screen Recording"
            return Problem(severity: .warning, symbol: "lock.shield", title: "Permission needed",
                           hint: "Glance needs \(what) for this. Allow it, then try again.", action: .permissions, detail: text)
        }
        if let status = httpStatus(text) {
            if has("deploymentnotfound", "deployment not ready", "provisioning", "is not ready", "deployment for this resource does not exist",
                   "api deployment") {
                return Problem(severity: .warning, symbol: "hourglass", title: "The model isn't ready yet",
                               hint: "Your Azure deployment is still being set up. Try again in a few minutes, or pick another provider in Settings.",
                               action: .settings, detail: text)
            }
            switch status {
            case 401, 403:
                return Problem(severity: .error, symbol: "key.slash", title: "The key was refused",
                               hint: "The provider didn't accept your API key. Check it in Settings.", action: .settings, detail: text)
            case 404:
                return Problem(severity: .error, symbol: "questionmark.circle", title: "Model or address not found",
                               hint: "Check the model name and address in Settings.", action: .settings, detail: text)
            case 429:
                return Problem(severity: .warning, symbol: "tortoise", title: "Too many requests",
                               hint: "The provider asked Pip to slow down. Wait a moment and ask again.", action: .retryLater, detail: text)
            case 500...599:
                return Problem(severity: .warning, symbol: "cloud.bolt", title: "The provider is having trouble",
                               hint: "It's not you. Try again in a minute.", action: .retryLater, detail: text)
            default:
                return Problem(severity: .error, symbol: "exclamationmark.bubble", title: "The provider sent an error",
                               hint: "Pip couldn't get an answer this time.", detail: text)
            }
        }
        if has("elevenlabs") {
            return Problem(severity: .info, symbol: "speaker.badge.exclamationmark", title: "Voice had a hiccup",
                           hint: "Answers still show here as text.", detail: text)
        }
        if text.count <= 90 { // short notices ("Didn't catch that…") are already friendly
            return Problem(severity: .warning, symbol: "exclamationmark.circle", title: text, hint: "")
        }
        return Problem(severity: .error, symbol: "exclamationmark.circle", title: "Something went wrong",
                       hint: "Pip couldn't finish that.", detail: text)
    }

    /// The panel status line only becomes a card for problems, never for normal prompts.
    static func fromStatus(_ status: String) -> Problem? {
        let lower = status.lowercased()
        return lower.contains("ocr unavailable") || lower.contains("couldn't read the screen") ? classify(status) : nil
    }

    /// Memory state as a panel chip; nil while recording normally.
    static func memory(_ state: MemoryRecorder.State) -> Problem? {
        switch state {
        case .recording: return nil
        case .paused:
            return Problem(severity: .info, symbol: "pause.circle", title: "Memory paused",
                           hint: "Nothing is being saved. Resume it from the menu bar.")
        case .skipping(let why):
            if ["Glance itself", "no frontmost app"].contains(why) { return nil }
            let plain = switch why {
            case "password field": "you're typing in a password field"
            case "private window": "this is a private window"
            case "excluded app": "this app is on the never-record list"
            case "blocked site": "this site is on the never-record list"
            default: why
            }
            return Problem(severity: .info, symbol: "eye.trianglebadge.exclamationmark", title: "Not saving this window",
                           hint: "Memory skips it because \(plain).")
        case .off(let why):
            return Problem(severity: .warning, symbol: "eye.slash", title: "Memory is off",
                           hint: why.contains("Screen Recording") ? "It needs Screen Recording permission." : "Reason: \(why).",
                           action: why.contains("Screen Recording") ? .permissions : nil)
        }
    }

    static func httpStatus(_ text: String) -> Int? {
        guard let r = text.range(of: #"HTTP (\d{3})"#, options: .regularExpression) else { return nil }
        return Int(text[r].dropFirst(5))
    }

    @MainActor
    static func perform(_ action: Action) {
        switch action {
        case .settings: NSApp.sendAction(Selector(("showSettings")), to: nil, from: nil)
        case .permissions: NSApp.sendAction(Selector(("showOnboarding")), to: nil, from: nil)
        case .relaunch:
            let path = Bundle.main.bundlePath
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
            try? p.run()
            NSApp.terminate(nil)
        case .retryLater: break
        }
    }

    static func selfTest(_ check: (Bool, String) -> Void) {
        check(classify(AIError.missingKey("DeepSeek").localizedDescription).title == "Add an API key"
              && classify(AIError.missingKey("DeepSeek").localizedDescription).hint.contains("DeepSeek"), "problem: no API key")
        let azure = AIError.http(404, #"{"error":{"code":"DeploymentNotFound","message":"The API deployment for this resource does not exist."}}"#)
        check(classify(azure.localizedDescription).title == "The model isn't ready yet"
              && classify(azure.localizedDescription).detail?.contains("DeploymentNotFound") == true, "problem: Azure deployment not ready, raw text in details")
        check(classify(AIError.http(401, "bad key").localizedDescription).action == .settings, "problem: 401 → check key")
        check(classify(AIError.http(503, "").localizedDescription).title == "The provider is having trouble", "problem: 5xx")
        check(classify(URLError(.notConnectedToInternet).localizedDescription).symbol == "wifi.slash"
              && classify("The Internet connection appears to be offline.").symbol == "wifi.slash", "problem: offline")
        check(classify(VoiceError.noMicrophone.localizedDescription).action == .permissions, "problem: microphone permission")
        check(classify("Couldn't read the screen: The user declined TCCs").action == .permissions, "problem: screen permission")
        check(classify("\(ChatModel.macVoiceNotice) (HTTP 402)").severity == .info
              && classify("\(ChatModel.macVoiceNotice) (HTTP 402)").detail == "HTTP 402", "problem: Mac voice is info, reason in details")
        check(classify("OCR unavailable — relaunch Glance.").action == .relaunch && fromStatus("OCR unavailable — relaunch Glance.") != nil,
              "problem: OCR unavailable offers relaunch")
        check(fromStatus("Pointing at Safari. Ask about it.") == nil, "problem: normal status stays a status")
        check(classify(VoiceError.nothingHeard.localizedDescription).title == VoiceError.nothingHeard.localizedDescription,
              "problem: short friendly notices pass through")
        check(classify(String(repeating: "x", count: 200)).detail?.count == 200, "problem: long unknown text goes to details")
        check(classify("Cancelled. Nothing was sent.").severity == .info, "problem: Cancel is informational")
        check(classify("Local only is on, so Glance didn't contact api.deepseek.com.").title == "Kept on this Mac"
              && classify("Local only is on, so Glance didn't contact api.deepseek.com.").detail?.contains("deepseek") == true,
              "problem: Local-only gate refusal")
        check(classify("Apple's on-device model isn't available (model not ready).").action == .settings, "problem: no on-device model")
        check(memory(.recording) == nil && memory(.skipping("Glance itself")) == nil, "problem: no memory chip while recording")
        check(memory(.skipping("password field"))?.hint.contains("password") == true && memory(.paused)?.title == "Memory paused"
              && memory(.off("needs Screen Recording permission"))?.action == .permissions, "problem: memory paused / not saving / off")
    }
}

/// A designed card for a Problem, used in the panel thread and for memory/status chips.
struct ProblemCard: View {
    let problem: Problem
    var compact = false
    @State private var showDetail = false

    private var tint: Color {
        switch problem.severity {
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: problem.symbol)
                .font(compact ? .callout : .title3)
                .foregroundStyle(tint)
                .frame(width: compact ? 18 : 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(problem.title).font(compact ? .callout.weight(.semibold) : .body.weight(.semibold))
                if !problem.hint.isEmpty {
                    Text(problem.hint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if problem.action != nil || problem.detail != nil {
                    HStack(spacing: 12) {
                        if let action = problem.action, let label = label(action) {
                            Button(label) { Problem.perform(action) }.controlSize(.small)
                        }
                        if problem.detail != nil {
                            Button(showDetail ? "Hide details" : "Details") { showDetail.toggle() }
                                .buttonStyle(.link).controlSize(.small)
                        }
                    }
                    .padding(.top, 2)
                }
                if showDetail, let detail = problem.detail {
                    Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(compact ? 8 : 10)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.25)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(problem.title). \(problem.hint)")
    }

    private func label(_ action: Problem.Action) -> String? {
        switch action {
        case .settings: "Open Settings"
        case .permissions: "Open Permissions"
        case .relaunch: "Relaunch Glance"
        case .retryLater: nil
        }
    }
}
