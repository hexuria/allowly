import Foundation
import JevCore
import JevServer

/// Push subscriptions and the VAPID identity behind them.
///
/// All of this existed and was never called: the crypto was written, the
/// service worker handled the event, and nothing in between was connected — so
/// an approval could only ever be seen by someone already looking at the app.
final class PushStore: @unchecked Sendable {
    static let shared = PushStore()

    private let lock = NSLock()
    private var subscriptions: [String: PushSubscription] = [:]   // endpoint -> subscription
    private var vapid: VAPID?

    private static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/jev", isDirectory: true)
    }

    private static var subscriptionsURL: URL {
        directory.appendingPathComponent("push-subscriptions.json")
    }

    init() {
        load()
        vapid = try? VAPID.loadOrGenerate(storageURL: Self.directory)
    }

    /// The application server key the browser needs in order to subscribe.
    var publicKey: String? {
        lock.lock(); defer { lock.unlock() }
        return vapid?.publicKeyBase64URL
    }

    func add(_ subscription: PushSubscription) {
        lock.lock()
        subscriptions[subscription.endpoint] = subscription
        let snapshot = subscriptions
        lock.unlock()
        save(snapshot)
        JevLog.write("[jev] push subscription registered (\(snapshot.count) device(s))")
    }

    var all: [PushSubscription] {
        lock.lock(); defer { lock.unlock() }
        return Array(subscriptions.values)
    }

    /// Notify every paired device. Subscriptions the push service reports as
    /// gone are dropped rather than retried forever.
    func notify(title: String, body: String, url: URL?) async {
        lock.lock()
        let targets = Array(subscriptions.values)
        let identity = vapid
        lock.unlock()

        guard let identity, !targets.isEmpty else { return }
        let sender = PushSender(vapid: identity, subscriberEmail: "mailto:jev@localhost")
        let notification = PushNotification(title: title, body: body, actionURL: url)

        for subscription in targets {
            do {
                try await sender.send(notification: notification, to: subscription)
            } catch let error as PushError {
                if case .subscriptionExpired = error {
                    drop(subscription)
                    JevLog.write("[jev] push subscription expired, removed")
                } else {
                    JevLog.write("[jev] push failed: \(error.description)")
                }
            } catch {
                // URLSession errors dump a page of NSError detail; the code and
                // message are the only useful part.
                let nsError = error as NSError
                JevLog.write("[jev] push failed: \(nsError.localizedDescription) (\(nsError.code))")
            }
        }
    }

    private func drop(_ subscription: PushSubscription) {
        lock.lock()
        subscriptions.removeValue(forKey: subscription.endpoint)
        let snapshot = subscriptions
        lock.unlock()
        save(snapshot)
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.subscriptionsURL),
              let stored = try? JSONDecoder().decode([PushSubscription].self, from: data) else { return }
        subscriptions = Dictionary(uniqueKeysWithValues: stored.map { ($0.endpoint, $0) })
    }

    private func save(_ snapshot: [String: PushSubscription]) {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Array(snapshot.values)) else { return }
        try? data.write(to: Self.subscriptionsURL, options: .atomic)
    }
}
