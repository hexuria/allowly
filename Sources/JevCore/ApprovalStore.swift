import Foundation

public actor ApprovalStore: Sendable {
    private var pendingRequests: [String: ApprovalRequest] = [:]
    private let expirationInterval: TimeInterval = 300 // 5 minutes

    /// Cards that must not age out, because the thing they are about is
    /// still on screen waiting.
    ///
    /// Five minutes is the right life for a card about a moment that has
    /// passed — a spoken command nobody answered means something else by
    /// now. It is the wrong life for a macOS permission dialog, which sits
    /// there indefinitely until somebody answers it. Measured: a TCC prompt
    /// went up, jev pushed a notification, the card was destroyed five
    /// minutes later, and the dialog was still on screen eight minutes
    /// after that — a notification pointing at a card that no longer
    /// existed, and a dialog that could no longer be answered from the
    /// phone at all.
    ///
    /// The store cannot see a screen, so it is told. The sweep already asks
    /// `DialogRegistry.isLive` every two seconds and now says so here.
    private var held: Set<String> = []

    /// The longest a card may outlive its ordinary five minutes.
    ///
    /// Holding a card while its dialog is on screen fixed a real problem — a
    /// macOS permission prompt waits indefinitely and its card was destroyed
    /// at five minutes. It also made a MISTAKE permanent: the watcher can
    /// raise a card for something that is not a dialog at all, and "still on
    /// screen" is just as true of that. An hour is long enough for the prompt
    /// you walked away from and short enough that nothing is stuck forever.
    private let holdLimit: TimeInterval = 60 * 60

    /// Still worth showing: not yet aged out, or held open because its
    /// dialog is still there.
    private func isFresh(_ request: ApprovalRequest, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(request.timestamp)
        if age <= expirationInterval { return true }
        return held.contains(request.id) && age <= expirationInterval + holdLimit
    }

    /// Keep this card for as long as its dialog is on screen.
    ///
    /// Returns true only the first time, so the caller can say so once
    /// rather than every two seconds — and so there is a positive line in
    /// the log for a card being kept, instead of only the absence of the
    /// line that used to take it away.
    @discardableResult
    public func hold(id: String) -> Bool {
        guard pendingRequests[id] != nil else { return false }
        return held.insert(id).inserted
    }

    /// Let it age out again — its dialog has gone.
    public func release(id: String) {
        held.remove(id)
    }

    public func isHeld(id: String) -> Bool { held.contains(id) }

    /// Every card in the store, aged out or not.
    ///
    /// The sweep is the one caller that has to see an expired card, because
    /// it is the only one that can tell whether it should have expired.
    public func everyPending() -> [ApprovalRequest] { Array(pendingRequests.values) }

    public init() {}

    /// Add a new approval request to the store.
    /// Add a request unless an equivalent one is already waiting.
    ///
    /// Repeating a command that is already queued should not produce a second
    /// card to dismiss; saying something three times because nothing appeared
    /// to happen is normal, and the queue should absorb that.
    /// The body counts too, not just the heading.
    ///
    /// An untitled sheet takes its app's name as a heading, and a great
    /// many sheets are untitled — so keying on the heading alone made every
    /// button-only sheet from one app identical to every other. Chrome's
    /// "Close Tab and Delete Group?" would have swallowed a "Leave site?"
    /// raised thirty seconds later, and the second dialog would never have
    /// reached the phone at all while its app sat waiting on it. Two
    /// dialogs are the same dialog only if they say the same thing AND
    /// offer the same answers.
    public func addDeduplicated(_ request: ApprovalRequest) -> Bool {
        func identity(_ r: ApprovalRequest) -> String {
            // The body is part of the identity for a DIALOG, whose title is
            // often just its app's name — but not for a spoken command,
            // whose body is the transcript. Saying "skip", then "click
            // skip", then "press the skip button" builds the same command
            // with the same title and three different bodies, and this
            // rule turned one card into three, each of which would click
            // Skip again. That is the exact case the method exists to
            // absorb.
            let body = r.kind == .spokenCommand ? "" : r.bodyText
            return "\(r.title)\u{1F}\(body)\u{1F}\(r.options.map(\.id).joined(separator: "\u{1E}"))"
        }
        let wanted = identity(request)
        let duplicate = pendingRequests.values.contains { existing in
            identity(existing) == wanted
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
    ///
    /// Expired means expired, even before the sweep has got to it. Without
    /// this, a card that aged out minutes ago was still answerable for as
    /// long as nothing reaped it — and nothing reaps it at all when
    /// Accessibility is not granted, because the sweep never starts.
    public func get(id: String) -> ApprovalRequest? {
        guard let request = pendingRequests[id], isFresh(request) else { return nil }
        return request
    }

    /// Resolve a request by id and remove it from pending.
    ///
    /// Removing an expired one is fine — that is what resolving means —
    /// but it must not be HANDED BACK as if it were still answerable.
    /// `executeAnswerAgentPrompt` treats a non-nil return as permission
    /// to act, so an agent prompt that aged out was still answerable
    /// while `get(id:)` had already stopped acknowledging it.
    public func resolve(id: String) -> ApprovalRequest? {
        guard let request = pendingRequests.removeValue(forKey: id) else { return nil }
        defer { held.remove(id) }
        return isFresh(request) ? request : nil
    }

    /// Requests that have just aged out — removed, and handed back so
    /// somebody can say so.
    ///
    /// `getAllPending` drops them silently, which left the phone showing a
    /// card the Mac had already forgotten: tapping it answered "No pending
    /// approval with that id", and since nothing ever broadcast `resolved`
    /// for it, the card stayed on screen until the app was reopened. A card
    /// that cannot be answered and cannot be dismissed is the worst state
    /// this app has.
    public func reapExpired() -> [ApprovalRequest] {
        let now = Date()
        var reaped: [ApprovalRequest] = []
        for (id, request) in pendingRequests where !isFresh(request, now: now) {
            pendingRequests.removeValue(forKey: id)
            held.remove(id)
            reaped.append(request)
        }
        return reaped
    }

    /// Get all pending requests. Expired ones are hidden but NOT removed.
    ///
    /// Removal belongs to `reapExpired` alone, because removal is the thing
    /// somebody has to announce. While this also reaped, whichever of the
    /// two ran first won — and `/api/pending`, which the phone now calls
    /// every time you come back to the app, could quietly delete a request
    /// before the sweep ever saw it. No `resolved` was broadcast, the AX
    /// handle stayed in the registry for its full 15 minutes, and a second
    /// paired device kept a card it could never answer. That is the exact
    /// state `reapExpired` was written to eliminate.
    public func getAllPending() -> [ApprovalRequest] {
        let now = Date()
        return pendingRequests.values.filter { isFresh($0, now: now) }
    }

    /// Count of pending requests. Also non-mutating, for the same reason.
    public func count() -> Int {
        let now = Date()
        return pendingRequests.values.count { isFresh($0, now: now) }
    }

    /// Clear all pending requests.
    public func clear() {
        pendingRequests.removeAll()
        held.removeAll()
    }
}
