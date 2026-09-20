import Foundation
import AppKit

/// What was in front of the person when they spoke — gathered once, then
/// handed to every stage that interprets the sentence.
///
/// This used to be ambient. `Phrasebook.context()` was a global any code
/// could call at any instant, and it was called a hundred and four times
/// per spoken command — once per binding while building the capability
/// list — and then again a model round-trip later when the chosen
/// capability was built. So the list was filtered under one scope and the
/// command executed under another: "focus the address bar" could be chosen
/// as ⌘L and run as ⌘F if the front window changed in between. Two stages
/// on the hot path were handed `Phrasebook.neutral` — an empty scope —
/// purely so they would not shell out to osascript from inside the actor.
///
/// Built once, the same reading reaches every stage, nothing has to be
/// re-read mid-sentence, nothing has to be emptied to avoid blocking, and a
/// test can hand in whatever scope it likes.
///
/// Everything here is the `Sendable` result of reads that already happened
/// elsewhere; this only makes them happen once.
struct Scope: Sendable {
    /// Frontmost app and, when it is a browser, the page's host.
    let context: Phrasebook.Context
    /// The app the visible labels came from, as the driver reports it. Can
    /// differ from `context.appName` when the two oracles disagree — the
    /// driver has recorded them disagreeing in production — and the labels
    /// belong with this one.
    let app: String
    /// What is on screen right now, from the accessibility driver.
    let visibleLabels: [String]
    /// The control the pointer is resting on, if any — the innermost scope.
    /// Scope bubbles outward from here: cursor, then the window (what is
    /// visible, and the page in a browser), then the app, then the
    /// workspace, then global. The innermost claim on a sentence wins,
    /// exactly as macOS resolves a keystroke from the first responder
    /// outward. App sits inside workspace in that order because what a word
    /// means in one app ("mute" on YouTube) is more specific than what it
    /// means to the workspace (switching, moving windows).
    let underPointer: String?
    /// Every app with a process, by localized name.
    let runningApps: Set<String>
    /// The workspaces that exist and the one in front, when a window manager
    /// can say. Empty otherwise — a closed choice over nothing offers nothing.
    let workspaces: [String]
    let workspace: String?
    /// Which manager answered. Spaces when nothing else did.
    let workspaceManager: WorkspaceManager.Kind
    let takenAt: Date

    /// Read the world once.
    static func current() async -> Scope {
        let seen = await CommandExecutor.cua.frontmostContext()
        let context = Phrasebook.context()
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.localizedName))
        // Same snapshot as the labels, so the pointer's control is one the
        // classifier is also being offered.
        let pointed = await CommandExecutor.cua.labelUnderPointer(at: Pointer.location())
        // Whichever manager answers, not whichever binary exists.
        let manager = WorkspaceManager.detect()
        return Scope(context: context,
                     app: seen.app ?? context.appName,
                     visibleLabels: seen.labels,
                     underPointer: pointed,
                     runningApps: running,
                     workspaces: manager.workspaces,
                     workspace: manager.focused,
                     workspaceManager: manager.kind,
                     takenAt: Date())
    }

    /// For tests: nothing in front, nothing on screen.
    static let empty = Scope(context: Phrasebook.neutral, app: "", visibleLabels: [],
                             underPointer: nil, runningApps: [], workspaces: [],
                             workspace: nil, workspaceManager: .spaces, takenAt: Date())
}
