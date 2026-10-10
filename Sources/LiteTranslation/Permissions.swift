import AppKit
import ApplicationServices

/// The two privacy grants the app relies on.
enum Permissions {
    /// Needed to read the selection in other apps.
    static var accessibility: Bool { AXIsProcessTrusted() }

    /// Needed to capture the window being read. Without it translations still work, just
    /// without on-screen context.
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    static func promptForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func promptForScreenRecording() {
        CGRequestScreenCaptureAccess()
    }

    static func openAccessibilitySettings() {
        openPrivacyPane("Privacy_Accessibility")
    }

    static func openScreenRecordingSettings() {
        openPrivacyPane("Privacy_ScreenCapture")
    }

    private static func openPrivacyPane(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}
