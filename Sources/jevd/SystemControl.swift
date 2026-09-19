import Foundation
import JevCore

/// System state that no keystroke reaches reliably: volume, brightness,
/// appearance.
///
/// Driven through osascript with an argv array, never a shell string. The
/// allowlisted-command path deliberately rejects quotes and parentheses, and
/// every one of these scripts contains both — routing them through it would
/// have failed at runtime.
enum SystemControl {
    /// Current output volume, 0-100.
    static func volume() -> Int? {
        guard let out = runScript("output volume of (get volume settings)") else { return nil }
        return Int(out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func setVolume(_ level: Int) -> ExecutionResult {
        let clamped = max(0, min(100, level))
        guard runScript("set volume output volume \(clamped)") != nil else {
            return .failed(reason: "Could not set the volume")
        }
        // Read it back. The script exiting zero only says osascript ran; it
        // says nothing about the volume actually moving, and on a machine with
        // no output device it will not.
        if let actual = volume(), abs(actual - clamped) > 3 {
            return .failed(reason: "Asked for \(clamped)% but the volume is \(actual)%")
        }
        return .ok(reason: "Volume \(clamped)%")
    }

    static func nudgeVolume(by delta: Int) -> ExecutionResult {
        guard let current = volume() else {
            return .failed(reason: "Could not read the current volume")
        }
        // Unmute on the way up: turning it up while muted otherwise does
        // nothing audible and looks broken. If the unmute itself fails, say
        // so — the number changing while you still hear nothing is worse than
        // an error.
        if delta > 0, runScript("set volume without output muted") == nil {
            return .failed(reason: "Could not unmute, so turning it up would not be audible")
        }
        return setVolume(current + delta)
    }

    static func setMuted(_ muted: Bool) -> ExecutionResult {
        guard runScript("set volume \(muted ? "with" : "without") output muted") != nil else {
            return .failed(reason: "Could not change mute")
        }
        return .ok(reason: muted ? "Muted" : "Unmuted")
    }

    static func nudgeBrightness(up: Bool) -> ExecutionResult {
        // There is no public API for display brightness, and the System Events
        // property is unreliable, so use the hardware keys. The keystroke can
        // fail — no accessibility trust, no event source — and discarding that
        // reported "Brighter" when nothing had been pressed at all.
        let pressed = Keystrokes.press(up ? "f2" : "f1")
        guard pressed.status == .ok else {
            return .failed(reason: "Could not press the brightness key: \(pressed.reason)")
        }
        return .ok(reason: up ? "Brighter" : "Dimmer")
    }

    static func toggleDarkMode() -> ExecutionResult {
        let script = "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"
        guard runScript(script) != nil else {
            return .failed(reason: "Could not change appearance")
        }
        return .ok(reason: "Switched appearance")
    }

    static func emptyTrash() -> ExecutionResult {
        // Finder still confirms this itself, which is the safety net.
        guard runScript("tell application \"Finder\" to empty the trash") != nil else {
            return .failed(reason: "Finder refused")
        }
        return .ok(reason: "Emptied the trash")
    }

    @discardableResult
    private static func runScript(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
