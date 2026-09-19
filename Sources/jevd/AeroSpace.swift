import Foundation
import JevCore

/// AeroSpace tiling window manager, driven through its CLI.
///
/// Workspace switching is not something accessibility can do — the window
/// manager owns it — so this shells out. argv only, never a shell string, and
/// the workspace id is validated against the workspaces that actually exist.
enum AeroSpace {
    private static let candidates = [
        "/opt/homebrew/bin/aerospace",
        "/usr/local/bin/aerospace",
    ]

    static var binary: String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isInstalled: Bool { binary != nil }

    static func workspaces() -> [String] {
        guard let output = run(["list-workspaces", "--all"]) else { return [] }
        return output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func focusedWorkspace() -> String? {
        run(["list-workspaces", "--focused"])?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func switchTo(_ id: String) -> ExecutionResult {
        guard isInstalled else {
            return .failed(reason: "AeroSpace is not installed")
        }
        // Only accept a workspace the window manager actually reports, so a
        // misheard "workspace tooth" cannot become an arbitrary argument.
        let available = workspaces()
        guard available.contains(id) else {
            return .failed(reason: "No workspace “\(id)” (have: \(available.joined(separator: ", ")))")
        }
        guard run(["workspace", id]) != nil else {
            return .failed(reason: "AeroSpace refused to switch to \(id)")
        }
        return .ok(reason: "Switched to workspace \(id)")
    }

    /// Pull the focused window onto the workspace you are looking at.
    ///
    /// AeroSpace parks windows off-screen to implement workspaces, so an app
    /// can be "activated" with every one of its windows invisible. Reporting
    /// that as success is how "open Chrome" looked like it did nothing.
    @discardableResult
    static func summonFocusedWindowHere() -> Bool {
        guard isInstalled, let workspace = focusedWorkspace() else { return false }
        return run(["move-node-to-workspace", workspace]) != nil
    }

    @discardableResult
    private static func run(_ arguments: [String]) -> String? {
        guard let binary else { return nil }
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
