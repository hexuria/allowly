import Foundation

public actor ApprovalStore: Sendable {
    private var pendingRequests: [String: ApprovalRequest] = [:]
    private let expirationInterval: TimeInterval = 300 // 5 minutes

    public init() {}

    /// Add a new approval request to the store.
    /// Add a request unless an equivalent one is already waiting.
    ///
    /// Repeating a command that is already queued should not produce a second
    /// card to dismiss; saying something three times because nothing appeared
    /// to happen is normal, and the queue should absorb that.
    public func addDeduplicated(_ request: ApprovalRequest) -> Bool {
        let duplicate = pendingRequests.values.contains { existing in
            existing.title == request.title
                && existing.originatingApp.bundleIdentifier == request.originatingApp.bundleIdentifier
                && request.timestamp.timeIntervalSince(existing.timestamp) < 120
        }
        guard !duplicate else { return false }
        add(request)
        return true
    }

    public func add(_ request: ApprovalRequest) {
        pendingRequests[request.id] = request
    }

    /// Retrieve a pending request by id.
    public func get(id: String) -> ApprovalRequest? {
        return pendingRequests[id]
    }

    /// Resolve a request by id and remove it from pending.
    public func resolve(id: String) -> ApprovalRequest? {
        return pendingRequests.removeValue(forKey: id)
    }

    /// Get all pending requests, removing expired ones.
    public func getAllPending() -> [ApprovalRequest] {
        let now = Date()
        var active: [ApprovalRequest] = []

        for (id, request) in pendingRequests {
            let age = now.timeIntervalSince(request.timestamp)
            if age > expirationInterval {
                pendingRequests.removeValue(forKey: id)
            } else {
                active.append(request)
            }
        }

        return active
    }

    /// Count of pending requests.
    public func count() -> Int {
        let now = Date()
        var count = 0

        for (id, request) in pendingRequests {
            let age = now.timeIntervalSince(request.timestamp)
            if age > expirationInterval {
                pendingRequests.removeValue(forKey: id)
            } else {
                count += 1
            }
        }

        return count
    }

    /// Clear all pending requests.
    public func clear() {
        pendingRequests.removeAll()
    }
}
