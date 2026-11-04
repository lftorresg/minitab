import Cocoa
import ApplicationServices
import ScreenCaptureKit

enum Permissions {
    enum Pane: String {
        case accessibility = "Privacy_Accessibility"
        case screenRecording = "Privacy_ScreenCapture"
    }

    static var accessibility: Bool { AXIsProcessTrusted() }
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    static func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Asks for Screen Recording. On recent macOS versions `CGRequestScreenCaptureAccess` alone
    /// may neither prompt nor put MiniTab back in the Screen Recording list after a reset;
    /// an actual ScreenCaptureKit query does both. It only lists windows; nothing is captured.
    static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        Task.detached(priority: .utility) {
            _ = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        }
    }

    @MainActor
    static func openSettings(_ pane: Pane) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }
}
