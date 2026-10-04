import AVFoundation
import ApplicationServices
import CoreGraphics

/// The three macOS permissions Glance needs. Grants are tied to the app's code signature,
/// so builds must be signed with the stable "Glance Dev" identity (see scripts/build-app.sh).
enum Permission: CaseIterable, Identifiable {
    case screenRecording, accessibility, microphone
    var id: Self { self }

    var title: String {
        switch self {
        case .screenRecording: "Screen Recording"
        case .accessibility: "Accessibility"
        case .microphone: "Microphone"
        }
    }

    var reason: String {
        switch self {
        case .screenRecording: "To see what's on your screen when you ask."
        case .accessibility: "To find buttons and fields so it can highlight them."
        case .microphone: "So you can talk to it instead of typing."
        }
    }

    var symbol: String {
        switch self {
        case .screenRecording: "rectangle.dashed.badge.record"
        case .accessibility: "hand.point.up.left"
        case .microphone: "mic"
        }
    }

    var isGranted: Bool {
        switch self {
        case .screenRecording: CGPreflightScreenCaptureAccess()
        case .accessibility: AXIsProcessTrusted()
        case .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    }

    func request() {
        switch self {
        case .screenRecording:
            CGRequestScreenCaptureAccess()
        case .accessibility:
            let key = "AXTrustedCheckOptionPrompt" as CFString
            AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
    }

    static var allGranted: Bool { allCases.allSatisfy(\.isGranted) }
}
