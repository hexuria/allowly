import Foundation
import AppKit

/// Helper for managing screen recording permission.
/// Screen Recording permission cannot be pre-granted by configuration profile — the user must approve it once, in person.
public struct ScreenRecordingPermission {
    public init() {}

    /// Checks whether the app has screen recording permission.
    /// - Returns: true if permission is granted, false otherwise.
    public func hasPermission() -> Bool {
        return CGPreflightScreenCaptureAccess()
    }

    /// Requests screen recording permission by opening System Preferences.
    /// After calling this, the user will see a one-time system prompt to allow screen recording for the app.
    /// This deep-links to the Screen Recording pane in System Preferences.
    public func requestPermission() {
        let preferencesURL = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenRecording"
        )!
        NSWorkspace.shared.open(preferencesURL)
    }

    /// Opens the Security & Privacy pane in System Preferences to the Screen Recording section.
    /// Use this if you want to guide the user to manually enable screen recording.
    public func openScreenRecordingSettings() {
        let preferencesURL = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenRecording"
        )!
        NSWorkspace.shared.open(preferencesURL)
    }
}
