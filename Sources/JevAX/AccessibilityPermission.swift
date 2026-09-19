import Foundation
import ApplicationServices

/// AccessibilityPermission provides helpers for checking and requesting Accessibility permission.
public struct AccessibilityPermission {
    /// Check if the current process is trusted by the Accessibility system.
    public static func isTrusted() -> Bool {
        return AXIsProcessTrusted()
    }

    /// Request Accessibility permission by triggering the system prompt.
    /// This will show the system dialog on macOS.
    /// Returns true if the process is trusted after the attempt.
    public static func requestTrust() -> Bool {
        let options: CFDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        let isTrusted = AXIsProcessTrustedWithOptions(options)
        return isTrusted
    }

    /// Generate the deep link to the Accessibility privacy pane in System Settings.
    public static func accessibilitySettingsURL() -> URL? {
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    /// Check trust status and optionally prompt if not trusted.
    /// Returns true if trusted after the check.
    public static func ensureTrusted(prompt: Bool = true) -> Bool {
        if isTrusted() {
            return true
        }

        if prompt {
            return requestTrust()
        }

        return false
    }
}
