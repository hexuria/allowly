import Foundation

/// The one connection jev keeps to the browser.
///
/// Chrome asks the person to allow **each new debugging connection**, not each
/// browser session. Opening one per task therefore means a dialog per task,
/// which nobody would use — measured, not assumed: connecting per goal
/// prompted every time, and running two goals through a single connection
/// prompted once.
///
/// So the connection is opened on the first web task and kept. That is a
/// posture worth being explicit about rather than burying: for as long as jevd
/// runs, it holds an open channel capable of driving a signed-in browser. It
/// does not gain a capability it lacked — the endpoint is readable by anything
/// running as this user, which is the door Chrome's own opt-in already opened
/// — but it does turn "allowed once, just now" into "allowed until Chrome or
/// jev restarts". Chrome's prompt is the consent, and this holds it rather
/// than asking again every time.
///
/// One tab, reused. A tab per task would leave a trail of them in someone's
/// browser within a morning; reusing one keeps the last task visible, which is
/// what "leave it open" was for.
public actor WebBrowser {

    public static let shared = WebBrowser()

    private var session: WebSession?
    private var endpoint: ChromeDiscovery.Endpoint?

    public init() {}

    public enum Failure: Error, Sendable {
        /// No live endpoint. Carries the sentence to show the person.
        case unavailable(String)
        case session(WebSession.Failure)
    }

    /// A session that is connected and has a tab, reconnecting if it has to.
    public func acquire() async throws -> WebSession {
        if let session = self.session {
            do {
                try await session.ensureReady()
                return session
            } catch {
                // The endpoint may have moved — a restarted Chrome writes a new
                // port and a new browser id — so rediscover rather than retry
                // against an address that no longer answers.
                self.session = nil
                self.endpoint = nil
            }
        }

        let lookup = await ChromeDiscovery.lookup()
        guard case .found(let endpoint) = lookup else {
            throw Failure.unavailable(ChromeDiscovery.explain(lookup))
        }
        self.endpoint = endpoint

        let session = WebSession(endpoint: endpoint)
        do { try await session.ensureReady() }
        catch let failure as WebSession.Failure { throw Failure.session(failure) }
        self.session = session
        return session
    }

    /// Let go of the connection. For shutdown, and for a person who would
    /// rather jev were not holding one.
    public func release() async {
        await session?.detach()
        session = nil
        endpoint = nil
    }

    /// Whether a connection is currently held.
    public var isConnected: Bool { session != nil }
}
