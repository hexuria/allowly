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
