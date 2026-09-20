import Foundation
import AppKit
import JevCore

/// Whichever thing owns workspaces on this Mac, found by asking, not by
/// assuming.
///
/// "workspace 3" meant AeroSpace and only AeroSpace, chosen because its
/// binary existed on disk — so with AeroSpace installed but quit, the answer
/// was `No workspace "3" (have: )`, and on a Mac with yabai it was nothing at
/// all. Each manager is now tried in turn and the first one that actually
/// ANSWERS wins: a CLI that lists workspaces is running; a binary that does
/// not answer is a file.
///
/// Order: AeroSpace, yabai, then macOS Spaces. Amethyst is not a level of its
/// own — it tiles windows within Spaces and has no CLI, so a Mac running it
/// is a Spaces Mac for switching purposes. Spaces itself cannot be listed
/// through any public API and can only be jumped to by the system ⌃N
/// shortcuts, which must be enabled in System Settings; this says so rather
/// than pretending to parity.
enum WorkspaceManager {

    enum Kind: String, Sendable { case aerospace, yabai, spaces }

    struct Detected: Sendable {
        let kind: Kind
        /// What exists, when the manager can say. Empty for Spaces.
        let workspaces: [String]
        let focused: String?
    }

    static func detect() -> Detected {
        // AeroSpace answers, or it is not there for our purposes.
        if AeroSpace.isInstalled {
            let listed = AeroSpace.workspaces()
            if !listed.isEmpty {
                return Detected(kind: .aerospace, workspaces: listed, focused: AeroSpace.focusedWorkspace())
            }
        }
        if let spaces = yabaiSpaces() {
            return Detected(kind: .yabai, workspaces: spaces.map(\.index),
                            focused: spaces.first { $0.focused }?.index)
        }
        return Detected(kind: .spaces, workspaces: [], focused: nil)
    }

    static func switchTo(_ id: String, using detected: Detected) -> ExecutionResult? {
        switch detected.kind {
        case .aerospace:
            return AeroSpace.switchTo(id)
        case .yabai:
            guard detected.workspaces.contains(id) else {
                return .failed(reason: "No space “\(id)” (have: \(detected.workspaces.joined(separator: ", ")))")
            }
            guard yabai(["-m", "space", "--focus", id]) != nil else {
                return .failed(reason: "yabai refused to focus space \(id)")
            }
            return .ok(reason: "Switched to space \(id)")
        case .spaces:
            // Not this function's to do: it is a keystroke, and keystrokes
            // go through the executor like every other one. Nil means "press
            // `spacesShortcut(for:)` instead".
            return nil
        }
    }

    /// The ⌃N shortcut for a Space, or nil when there is none to press.
    ///
    /// Pure. macOS binds ⌃1…⌃9 only, and only when "Switch to Desktop N" is
    /// enabled under Keyboard Shortcuts → Mission Control; a Space that does
    /// not exist simply does nothing when pressed, and there is no way to
    /// ask. Both facts are in the reason the executor reports.
    static func spacesShortcut(for id: String) -> String? {
        guard let n = Int(id), (1...9).contains(n) else { return nil }
        return "ctrl+\(n)"
    }

    // MARK: - yabai

    private static let yabaiCandidates = ["/opt/homebrew/bin/yabai", "/usr/local/bin/yabai"]

    static var yabaiBinary: String? {
        yabaiCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    struct YabaiSpace: Sendable, Equatable {
        let index: String
        let focused: Bool
    }

    /// Nil when yabai is absent or not answering; empty is not "nil".
    static func yabaiSpaces() -> [YabaiSpace]? {
        guard yabaiBinary != nil, let json = yabai(["-m", "query", "--spaces"]) else { return nil }
        return yabaiSpaces(fromJSON: Data(json.utf8))
    }

    /// Pure, so the parse is a launch assertion.
    static func yabaiSpaces(fromJSON data: Data) -> [YabaiSpace]? {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            guard let index = row["index"] as? Int else { return nil }
            let focused = (row["has-focus"] as? Bool) ?? ((row["focused"] as? Int) == 1)
            return YabaiSpace(index: String(index), focused: focused)
        }
    }

    @discardableResult
    private static func yabai(_ arguments: [String]) -> String? {
        guard let binary = yabaiBinary else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
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
