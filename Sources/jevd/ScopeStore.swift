import Foundation
import AppKit
import JevAX

/// The parts of scope that events keep current between commands.
///
/// Everything in `Scope` is read when a command arrives. Two of its inputs
/// were being read late: the running-app set was rebuilt from NSWorkspace
/// each time, and the accessibility snapshot was served from a two-second
/// cache — so a sentence spoken just after switching apps was matched
/// against the buttons of the app the person had just left. `DialogWatcher`
/// already receives a focus event from every running app and threw it away
/// unless the new window was a dialog. It is kept now.
///
/// What an event does: it marks the snapshot stale, so the NEXT command
/// re-reads rather than trusting the cache; and it refreshes the running set
/// off the command path. The expensive read — walking the window's
/// accessibility tree — stays on demand. There is no reason to read a
/// window nobody is about to speak to.
actor ScopeStore {
    static let shared = ScopeStore()

    /// The pure record of what happened, kept separately so it can be
    /// asserted without AppKit.
    struct Ledger: Sendable, Equatable {
        var focusedPid: pid_t?
        var focusChanges = 0
        var appChanges = 0
        var lastEventAt: Date?

        mutating func noteFocus(pid: pid_t, at now: Date) {
            let changed = pid != focusedPid
            focusedPid = pid
            if changed { focusChanges += 1 }
            lastEventAt = now
        }

        mutating func noteApps(at now: Date) {
            appChanges += 1
            lastEventAt = now
        }
    }

    private(set) var ledger = Ledger()
    private var running: Set<String> = []
    private var runningAt = Date.distantPast

    /// Wire the watcher's events in. Idempotent.
    func start() {
        DialogWatcher.onFocusChanged = { pid, _ in
            Task { await ScopeStore.shared.focusChanged(to: pid) }
        }
        DialogWatcher.onAppsChanged = {
            Task { await ScopeStore.shared.appsChanged() }
        }
        refreshRunning()
    }

    /// Raised when a prompt no remote tool can see takes focus. Set by the
    /// runtime, which is the only thing that can put a card on the phone.
    nonisolated(unsafe) static var onPrivilegedPrompt: (@Sendable (String) -> Void)?

    /// Is this a prompt drawn by the system on another user's behalf?
    ///
    /// Pure, and a closed list rather than a guess: these are the processes
    /// that draw password and authorisation boxes, all of them outside the
    /// login session and therefore outside Accessibility.
    static func isPrivilegedPrompt(_ appName: String) -> Bool {
        ["securityagent", "loginwindow", "authorizationhost", "coreauthui"]
            .contains(appName.lowercased().replacingOccurrences(of: " ", with: ""))
    }

    func focusChanged(to pid: pid_t) async {
        let before = ledger.focusedPid
        ledger.noteFocus(pid: pid, at: Date())
        guard before != pid else { return }
        // The one thing a stale snapshot must not survive.
        await CommandExecutor.cua.invalidateSnapshot()
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName {
            JevLog.write("[allowly] focus: \(name)")
            // The one prompt the dialog watcher structurally cannot see.
            //
            // A keychain or login box belongs to `_securityagent`, another
            // user, so Accessibility cannot attach and no window-created
            // notification ever arrives. Focus is the only signal there is —
            // and it was already being written to the log and thrown away,
            // which is why a password box could sit on the Mac all afternoon
            // with the phone showing nothing.
            if Self.isPrivilegedPrompt(name) {
                Self.onPrivilegedPrompt?(name)
            }
        }
    }

    func appsChanged() async {
        ledger.noteApps(at: Date())
        refreshRunning()
        await CommandExecutor.cua.invalidateSnapshot()
    }

    private func refreshRunning() {
        running = Set(NSWorkspace.shared.runningApplications.compactMap(\.localizedName))
        runningAt = Date()
    }

    /// The running set, current as of the last launch/exit event — or
    /// re-read if no event has arrived for a while, because the events are
    /// a fast path and the sweep is the guarantee.
    func runningApps() -> Set<String> {
        if Date().timeIntervalSince(runningAt) > 30 { refreshRunning() }
        return running
    }
}
