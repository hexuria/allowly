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
        Allowly.supportDirectory
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
        JevLog.write("[allowly] push subscription registered (\(snapshot.count) device(s))")
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

        guard !targets.isEmpty else { return }
        guard let identity else {
            // No signing identity means no notification can ever be
            // sent, and this line used to return in silence: no log, no
            // `lastFailure`, no banner. A corrupt key file put the
            // daemon here permanently and nothing anywhere said so.
            JevLog.write("[allowly] NOTHING IS REACHING YOUR PHONE — jev has no push signing key, "
                + "so no notification can be sent. Restarting jev regenerates one.")
            noteFailure("allowly has no push signing key")
            return
        }
        let sender = PushSender(vapid: identity, subscriberEmail: VAPIDSubject.configured)
        let notification = PushNotification(title: title, body: body, actionURL: url)

        for subscription in targets {
            do {
                try await sender.send(notification: notification, to: subscription)
                noteSuccess()
            } catch let error as PushError {
                if case .subscriptionExpired = error {
                    drop(subscription)
                    JevLog.write("[allowly] push subscription expired, removed")
                    // NOT `noteFailure(nil)`. An expired subscription is
                    // not evidence that the others are fine, and clearing
                    // here meant two paired phones where one is stale hid
                    // the other's 403 — decided by the order a dictionary
                    // happened to iterate in.
                } else {
                    JevLog.write("[allowly] push failed: \(error.description)")
                    noteFailure(error.description)
                }
            } catch {
                // URLSession errors dump a page of NSError detail; the code and
                // message are the only useful part.
                let nsError = error as NSError
                JevLog.write("[allowly] push failed: \(nsError.localizedDescription) (\(nsError.code))")
                noteFailure(nsError.localizedDescription)
            }
        }
    }

    /// Why the last notification did not arrive, for the settings sheet.
    ///
    /// A failed push is invisible by nature: the phone cannot tell "no
    /// dialog happened" from "the notification was rejected". Every send
    /// jev has ever made was refused by Apple with 403 `BadJwtToken` —
    /// for months, in the user's own log — and the only trace was one
    /// line in a file nothing reads. A dead notification path is the
    /// product not working, so it is now something the phone can show.
    private var failure: String?

    /// Read under the lock. It was a `private(set) var` read straight
    /// from an HTTP handler while a `notify` task could be writing it —
    /// an unsynchronised `String?` read/write, which is a retain/release
    /// race that takes the process down, in a type marked
    /// `@unchecked Sendable` so nothing would catch it.
    var lastFailure: String? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    private func noteFailure(_ reason: String?) {
        lock.lock()
        failure = reason
        lock.unlock()
        // A rejected credential is not a transient network blip: it will
        // reject every notification from now until someone changes
        // something, so say so in words rather than leaving a status code.
        if let reason, reason.contains("403") {
            JevLog.write("[allowly] NOTHING IS REACHING YOUR PHONE — the push service refused Allowly's "
                + "signing identity (\(VAPIDSubject.configured)). Notifications will keep failing "
                + "until ALLOWLY_VAPID_SUBJECT is set to a contact it accepts.")
        }
    }

    /// Clear it once one gets through.
    func noteSuccess() {
        lock.lock()
        failure = nil
        lock.unlock()
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
        subscriptions = Dictionary(stored.map { ($0.endpoint, $0) }, uniquingKeysWith: { _, newer in newer })
    }

    private func save(_ snapshot: [String: PushSubscription]) {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Array(snapshot.values)) else { return }
        // Pre-create 0600, then write ATOMICALLY.
        //
        // I removed `.atomic` here on the theory that it replaces the
        // inode and loses the mode. Measured on this machine, it does
        // not: Foundation copies the existing file's attributes onto the
        // temp before renaming, so 0600 survives every save. The only
        // write that ever landed at the umask default was the first one,
        // which is what the pre-create below fixes.
        //
        // So dropping atomicity bought nothing and cost real safety:
        // `save` is deliberately called outside the lock, and a
        // truncate-then-write can interleave with another save to leave
        // a half-file that `load` rejects — silently losing every push
        // subscription, on the feature that is the whole point of the
        // product when the phone is in a pocket.
        if !FileManager.default.fileExists(atPath: Self.subscriptionsURL.path) {
            FileManager.default.createFile(atPath: Self.subscriptionsURL.path, contents: nil,
                                           attributes: [.posixPermissions: 0o600])
        }
        try? data.write(to: Self.subscriptionsURL, options: .atomic)
        // Each subscription carries the endpoint plus the auth secret and
        // p256dh that encrypt to that phone. Same reasoning as the VAPID
        // key beside it: not world-readable.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                ofItemAtPath: Self.subscriptionsURL.path)
    }
}
