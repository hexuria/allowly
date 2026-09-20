import Foundation
import JevCore
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
    /// What is on screen right now, from the accessibility driver — read
    /// from the window under the cursor when there is one, not from whatever
    /// macOS calls active. Under a tiling manager those differ constantly.
    let visibleLabels: [String]
    /// Whether `app` and the labels came from the window under the cursor
    /// (true) or from the active app because nothing was under it (false).
    let fromCursor: Bool
    /// What macOS calls the active app, kept so a disagreement is visible.
    let activeApp: String
    /// The process owning the window the labels came from.
    let cursorPid: Int?
    /// The bundle id of the app the command acts on, for the permission key.
    let appBundleId: String?

    /// Which app a keystroke should be aimed at before it is posted.
    ///
    /// A keystroke is posted to the HID tap with no target, so it lands in
    /// whatever macOS thinks is active — and when the cursor is in Waz while
    /// macOS says Chrome, "close tab" resolved for Waz closed a Chrome tab.
    /// Nil when the two agree, which is the common case and costs nothing.
    var aim: Aim? {
        guard fromCursor, let pid = cursorPid, !app.isEmpty, app != activeApp else { return nil }
        return Aim(pid: pid, app: app)
    }

    /// What a permission is granted for.
    ///
    /// `Command.bundleIdentifier` files every keystroke and click under
    /// "system.keyboard" and "system.pointer", so "always allow" granted for
    /// typing into a terminal also covered typing into a bank. Typing and
    /// clicking are acts ON an app, and here the app is known, so the grant
    /// is per app — the same key "quit Chrome" already uses, which is what
    /// "always allow this app" on the card was always taken to mean.
    func policyKey(for command: Command) -> String? {
        guard let bucket = command.bundleIdentifier else { return nil }
        guard bucket == "system.keyboard" || bucket == "system.pointer",
              let app = appBundleId, !app.isEmpty else { return bucket }
        return app
    }

    /// A process that could be addressed by name.
    struct Process: Sendable, Equatable {
        let name: String
        let pid: Int
        let bundleId: String
    }

    /// Every app a sentence could be addressed to: the ones with a Dock icon.
    static func runningProcesses() -> [Process] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let name = app.localizedName else { return nil }
            return Process(name: name, pid: Int(app.processIdentifier),
                           bundleId: app.bundleIdentifier ?? "")
        }
    }

    /// "In Safari, close tab": a sentence that names the app it is for.
    ///
    /// Returns the scope re-pointed at that app and the sentence with the
    /// address removed, or nil when the sentence does not start that way —
    /// "install Homebrew" is not addressed to anything. Only a running app
    /// can be addressed, and the longest name wins so "Google Chrome" is not
    /// read as "Google" followed by "chrome …".
    ///
    /// The addressed app's controls are not read — the words are parsed in
    /// that app's vocabulary and the keystroke is aimed there, which is what
    /// "in Safari, close tab" needs; naming a control in a window nobody can
    /// see is a different request.
    func addressing(_ text: String, running: [Process],
                    context: (Process) -> Phrasebook.Context) -> (scope: Scope, rest: String)? {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard lower.hasPrefix("in ") else { return nil }
        let after = String(lower.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        let named = running
            .filter { proc in
                let name = proc.name.lowercased()
                guard after.hasPrefix(name) else { return false }
                let tail = after.dropFirst(name.count)
                return tail.isEmpty || tail.first == "," || tail.first == " "
            }
            .max { $0.name.count < $1.name.count }
        guard let target = named else { return nil }
        let rest = after.dropFirst(target.name.count)
            .trimmingCharacters(in: CharacterSet(charactersIn: ", "))
        guard !rest.isEmpty else { return nil }
        let scope = Scope(context: context(target),
                          app: target.name, visibleLabels: [],
                          // Deliberate, like a cursor: the address is the target.
                          fromCursor: true, activeApp: activeApp,
                          cursorPid: target.pid, appBundleId: target.bundleId,
                          monitorApps: monitorApps, underPointer: nil,
                          runningApps: runningApps, installedApps: installedApps,
                          workspaces: workspaces, workspace: workspace,
                          workspaceManager: workspaceManager, takenAt: takenAt)
        return (scope, rest)
    }
    /// The apps with a normal window on the display the cursor is on — the
    /// monitor level, between window and workspace. "What can we see" on a
    /// two-display Mac is this, not the frontmost window.
    let monitorApps: [String]
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
    /// Everything installed, by name — the widest ring of the global scope.
    /// From the catalogue, which is kept current by watching the application
    /// folders, so this costs nothing per command and is not stale.
    let installedApps: [String]
    /// The workspaces that exist and the one in front, when a window manager
    /// can say. Empty otherwise — a closed choice over nothing offers nothing.
    let workspaces: [String]
    let workspace: String?
    /// Which manager answered. Spaces when nothing else did.
    let workspaceManager: WorkspaceManager.Kind
    let takenAt: Date

    /// Read the world once.
    static func current() async -> Scope {
        let point = Pointer.location()
        let seen = await CommandExecutor.cua.context(at: point)  // app, pid, labels, underPointer
        let context = Phrasebook.context()
        let active = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        // Kept current by launch and exit events, not rebuilt per command.
        let running = await ScopeStore.shared.runningApps()
        // Same snapshot as the labels, so the pointer's control is one the
        // classifier is also being offered.
        let pointed = await CommandExecutor.cua.labelUnderPointer(at: point)
        // Whichever manager answers, not whichever binary exists.
        let manager = WorkspaceManager.detect()
        // The app the labels came from, else the one macOS calls active.
        let owner = seen.pid.flatMap { NSRunningApplication(processIdentifier: pid_t($0)) }
            ?? NSWorkspace.shared.frontmostApplication
        return Scope(context: context,
                     app: seen.app ?? context.appName,
                     visibleLabels: seen.labels,
                     fromCursor: seen.underPointer,
                     activeApp: active,
                     cursorPid: seen.pid,
                     appBundleId: owner?.bundleIdentifier,
                     monitorApps: Monitor.apps(visibleAt: point),
                     underPointer: pointed,
                     runningApps: running,
                     installedApps: AppCatalog.shared.all.map(\.name),
                     workspaces: manager.workspaces,
                     workspace: manager.focused,
                     workspaceManager: manager.kind,
                     takenAt: Date())
    }

    /// For tests: nothing in front, nothing on screen.
    static let empty = Scope(context: Phrasebook.neutral, app: "", visibleLabels: [],
                             fromCursor: false, activeApp: "", cursorPid: nil, appBundleId: nil, monitorApps: [],
                             underPointer: nil, runningApps: [], installedApps: [],
                             workspaces: [],
                             workspace: nil, workspaceManager: .spaces, takenAt: Date())
}


/// The monitor level: what is visible on the display the cursor is on.
enum Monitor {
    /// Apps owning a normal, on-screen window on the display containing the
    /// point, frontmost first. From the window server, so no driver and no
    /// accessibility permission is involved.
    static func apps(visibleAt point: CGPoint) -> [String] {
        var display = CGDirectDisplayID(0)
        var count: UInt32 = 0
        CGGetDisplaysWithPoint(point, 1, &display, &count)
        let bounds = count > 0 ? CGDisplayBounds(display) : Pointer.displayBounds()
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        return list.compactMap { window -> String? in
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let owner = window[kCGWindowOwnerName as String] as? String,
                  let rect = (window[kCGWindowBounds as String] as? [String: Any]).flatMap(rectFrom),
                  rect.intersects(bounds),
                  seen.insert(owner).inserted else { return nil }
            return owner
        }
    }

    static func rectFrom(_ dict: [String: Any]) -> CGRect? {
        guard let x = dict["X"] as? Double, let y = dict["Y"] as? Double,
              let w = dict["Width"] as? Double, let h = dict["Height"] as? Double else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

/// Where a keystroke is going.
struct Aim: Sendable, Equatable {
    let pid: Int
    let app: String
}
