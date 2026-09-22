import Foundation
import JevWeb

/// What the gateway will actually serve this key, for the menu bar to list.
///
/// `/v1/models` is built for this — its own doc comment says clients call it to
/// populate a picker — and the answer is per-caller rather than a catalogue
/// dump: the intersection of the route's ladder, the key's floor, and the
/// providers there are live credentials for. So an empty list is information,
/// not an error, and the `oag` envelope says which of those ran out.
///
/// ## Reading it without freezing the menu
///
/// `menuNeedsUpdate` rebuilds the whole menu on every open, and `runBlocking`
/// is launch-time-only by its own documentation, so the fetch cannot be
/// awaited while the menu is being built. The snapshot below is therefore read
/// synchronously under a lock and refreshed off-thread.
///
/// The lock is not decoration. Every target here is `.swiftLanguageMode(.v5)`,
/// so a `nonisolated(unsafe) static var` written by a background refresh and
/// read by the menu is a silent data race that the compiler will not mention.
enum ModelCatalog {

    // MARK: - What a model is

    struct Model: Equatable {
        let id: String
        let displayName: String
        let provider: String
        let tier: String?
        /// An `oag/*` rung, which picks a model for you rather than naming one.
        let isVirtual: Bool
        /// "sub" when this is a subscription seat rather than API credit.
        let channel: String?

        var usesSubscription: Bool { channel != nil || id.hasSuffix("@sub") }
    }

    /// Why the list is the shape it is. Never logged — see `summary`.
    struct Provider: Equatable {
        let name: String
        let serving: Bool
        let reason: String
    }

    struct Catalog: Equatable {
        let models: [Model]
        let providers: [Provider]
        let pressure: String?
    }

    /// What went wrong, when nothing came back.
    enum Failure: Equatable {
        case noKey
        case refused
        case unreachable(String)
        case unreadable

        var menuText: String {
            switch self {
            case .noKey:
                return "No gateway key — set ALLOWLY_OAG_API_KEY"
            case .refused:
                return "The gateway refused this key"
            case .unreachable:
                return "The gateway is not answering"
            case .unreadable:
                return "The gateway sent something unreadable"
            }
        }
    }

    // MARK: - Parsing

    /// Pure, so every shape the gateway can send is a launch assertion.
    static func parse(_ data: Data) -> Catalog? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["data"] as? [[String: Any]] else { return nil }

        let models: [Model] = entries.compactMap { entry in
            guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
            let meta = entry["oag"] as? [String: Any]
            return Model(
                id: id,
                // The gateway's own label when it has one, because "xAI:
                // grok-4.7" reads better in a menu than the bare id.
                displayName: (entry["display_name"] as? String) ?? id,
                provider: (meta?["provider"] as? String)
                    ?? (entry["owned_by"] as? String) ?? "unknown",
                tier: meta?["tier"] as? String,
                isVirtual: (meta?["virtual"] as? Bool) ?? id.hasPrefix("oag/"),
                channel: meta?["channel"] as? String)
        }

        // The envelope is optional: a gateway that does not send one still
        // gives a perfectly usable list.
        let envelope = root["oag"] as? [String: Any]
        let providers: [Provider] = (envelope?["providers"] as? [[String: Any]] ?? [])
            .compactMap { entry in
                guard let name = entry["provider"] as? String else { return nil }
                return Provider(name: name,
                                serving: (entry["serving"] as? Bool) ?? false,
                                reason: (entry["reason"] as? String) ?? "unknown")
            }
        let pressure = (envelope?["budget"] as? [String: Any])?["pressure"] as? String
        return Catalog(models: models, providers: providers, pressure: pressure)
    }

    // MARK: - Grouping

    /// Three sections, because the difference between them is what it costs.
    ///
    /// A plain model spends API credit, an `@sub` one spends a subscription
    /// seat, and an `oag/*` rung decides for you. Presenting those as one flat
    /// list would hide the only distinction that has a price attached.
    static func groups(_ models: [Model]) -> [(title: String, models: [Model])] {
        let plain = models.filter { !$0.isVirtual && !$0.usesSubscription }
        let subscription = models.filter { !$0.isVirtual && $0.usesSubscription }
        let automatic = models.filter(\.isVirtual)
        return [
            ("Models", plain),
            ("Subscription seat", subscription),
            ("Choose for me", automatic),
        ].filter { !$0.models.isEmpty }
    }

    /// One line for when the list is empty or something is not serving.
    ///
    /// Built from the envelope and shown in the menu, never written down. How
    /// much allowance is left is nobody's business but the owner's, so
    /// `remaining_pct` is read here and goes no further — a log line is
    /// forever and gets pasted into issues.
    static func summary(_ catalog: Catalog) -> String? {
        let stalled = catalog.providers.filter { !$0.serving }
        if catalog.models.isEmpty {
            guard !stalled.isEmpty else { return "The gateway is serving nothing right now" }
            let why = stalled.map { "\($0.name): \($0.reason)" }.joined(separator: ", ")
            return "No models — \(why)"
        }
        guard !stalled.isEmpty else { return nil }
        return "Not serving — " + stalled.map(\.name).joined(separator: ", ")
    }

    // MARK: - The snapshot the menu reads

    struct Snapshot {
        var catalog: Catalog?
        var failure: Failure?
        /// When a fetch last SUCCEEDED.
        var fetchedAt: Date?
        /// When one was last ATTEMPTED, success or not. Without this a refused
        /// key refires on every single menu open.
        var attemptedAt: Date?
        var inFlight = false
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var snapshot = Snapshot()

    /// How long an answer — or a failure — is good for.
    static let freshness: TimeInterval = 5 * 60

    /// Read by the menu. Takes the lock, copies, returns. Never waits on a
    /// network.
    static func current() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    static func isStale(_ snapshot: Snapshot, now: Date = Date()) -> Bool {
        guard let attempted = snapshot.attemptedAt else { return true }
        return now.timeIntervalSince(attempted) > freshness
    }

    /// Kick off a refresh if one is warranted and not already running.
    ///
    /// Returns immediately. The menu picks the result up the next time it is
    /// opened, which is the only moment it matters.
    static func refreshIfStale(force: Bool = false) {
        lock.lock()
        let shouldStart = !snapshot.inFlight && (force || isStale(snapshot))
        if shouldStart { snapshot.inFlight = true }
        lock.unlock()
        guard shouldStart else { return }
        Task.detached { await fetch() }
    }

    private static func publish(catalog: Catalog?, failure: Failure?) {
        lock.lock()
        snapshot.inFlight = false
        snapshot.attemptedAt = Date()
        if let catalog {
            snapshot.catalog = catalog
            snapshot.failure = nil
            snapshot.fetchedAt = Date()
        } else {
            // The last good list is kept. A momentary blip should not empty a
            // menu that was correct a minute ago.
            snapshot.failure = failure
        }
        lock.unlock()
    }

    private static func fetch() async {
        guard let key = WebTextModel.loadAPIKey() else {
            publish(catalog: nil, failure: .noKey)
            return
        }
        var request = URLRequest(url: WebTextModel.baseURL.appendingPathComponent("v1/models"))
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        // Five seconds, not the thirty `WebTextModel.text` allows: a menu is
        // waiting on this, even if it is not blocking on it.
        request.timeoutInterval = 5

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                // A 401 body carries no envelope, so there is nothing to
                // summarise — say what happened instead.
                publish(catalog: nil, failure: http.statusCode == 401 || http.statusCode == 403
                        ? .refused : .unreachable("HTTP \(http.statusCode)"))
                return
            }
            guard let catalog = parse(data) else {
                publish(catalog: nil, failure: .unreadable)
                return
            }
            publish(catalog: catalog, failure: nil)
        } catch {
            // The transport's own words, which name a refused connection or a
            // timeout without naming the key.
            publish(catalog: nil, failure: .unreachable(error.localizedDescription))
        }
    }
}
