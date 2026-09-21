import Foundation
import ApplicationServices

/// Keeps the live AXUIElement for each pending ApprovalRequest.
///
/// ApprovalRequest is Codable so it can go over the wire to the phone, which means
/// it cannot carry an AXUIElement. But answering an approval minutes later requires
/// pressing a button in the dialog that raised it, so something Mac-side has to hold
/// on to the element. That is this.
///
/// Entries expire: a dialog the user dismissed by hand is gone, and pressing a stale
/// element either silently fails or hits whatever replaced it on screen.
public final class DialogRegistry: @unchecked Sendable {
    public static let shared = DialogRegistry(ttl: 15 * 60)

    private struct Entry {
        let element: AXUIElement
        let registeredAt: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let ttl: TimeInterval

    public init(ttl: TimeInterval) {
        self.ttl = ttl
    }

    public func register(id: String, element: AXUIElement) {
        lock.lock()
        defer { lock.unlock() }
        expireLocked()
        entries[id] = Entry(element: element, registeredAt: Date())
    }

    /// The live element for this approval, or nil if it expired or was already resolved.
    public func element(for id: String) -> AXUIElement? {
        lock.lock()
        defer { lock.unlock() }
        expireLocked()
        return entries[id]?.element
    }

    /// Is this process still around?
    ///
    /// `kill(pid, 0)` sends nothing; it only asks. `ESRCH` is the one answer
    /// that means no such process — `EPERM` means it is there and not ours
    /// to signal, which is still there.
    public static func processExists(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    /// Pure, so the rule above is a launch assertion rather than a comment:
    /// a dialog is gone when its process has gone, or when AX says outright
    /// that the element is invalid. Anything else — a timeout from a busy
    /// app — leaves the card alone.
    public static func isGone(processExists: Bool, axSaysInvalid: Bool) -> Bool {
        !processExists || axSaysInvalid
    }

    /// Is this dialog still really on screen?
    ///
    /// `element(for:)` only says we once knew about it. A sheet the human
    /// dismissed at the Mac leaves its entry sitting here with a dead
    /// AXUIElement, and the card stays on the phone forever with nothing
    /// behind it — tapping Allow presses a dialog that is not there. The only
    /// way to know is to ask the element something and see if it answers.
    public func isLive(id: String) -> Bool {
        guard let element = element(for: id) else { return false }

        // Ask the kernel before asking Accessibility.
        //
        // AX answers `cannotComplete` for a process that has EXITED and for
        // one that is merely busy — the same code for "gone" and "beachballed
        // for a second". Below, that ambiguity is resolved in favour of
        // alive, which is right for a busy app and wrong for a dead one: a
        // card for a dialog whose app had quit was kept indefinitely, so the
        // next identical dialog was suppressed as a duplicate of a ghost and
        // never reached the phone. Measured, minutes after the hold that
        // made it possible went in.
        //
        // A process that has exited cannot have a dialog on screen, and
        // that question has an unambiguous answer.
        var owner: pid_t = 0
        if AXUIElementGetPid(element, &owner) == .success, owner > 0,
           !Self.processExists(owner) {
            return false
        }

        var value: AnyObject?
        let status = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        switch status {
        case .success:
            return true
        case .invalidUIElement:
            // The one answer that means the element is gone. Everything else
            // is the API being unhelpful.
            return false
        default:
            // `cannotComplete` in particular is a TIMEOUT, not a death
            // certificate: an app busy on its main thread — spinner,
            // beachball, a long save — stops answering AX for a second or
            // two while its sheet is plainly still on screen. Treating that
            // as dead let the 2-second sweep withdraw a live card, and
            // because the sweep also discards the registry entry, the dialog
            // could never be answered from the phone again. Losing a real
            // dialog is far worse than leaving a stale card up, so anything
            // short of `invalidUIElement` leaves the card alone.
            return true
        }
    }

    /// Every approval id we are still holding a dialog for.
    public func trackedIDs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        expireLocked()
        return Array(entries.keys)
    }

    /// Drop an entry once its approval has been answered.
    public func discard(id: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeValue(forKey: id)
    }

    public func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        expireLocked()
        return entries.count
    }

    private func expireLocked() {
        let cutoff = Date().addingTimeInterval(-ttl)
        entries = entries.filter { $0.value.registeredAt > cutoff }
    }
}
