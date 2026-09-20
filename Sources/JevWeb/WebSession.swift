import Foundation

/// A tab jev owns, inside the browser the person is already signed into.
///
/// The tab is created rather than borrowed. It lives in the same profile — so
/// the same cookies, the same logins, which is the entire point — but it is not
/// the tab the person is looking at, and input dispatched to it goes through
/// the DevTools target rather than the operating system. Nothing takes their
/// pointer, their keyboard or their foreground window. That is a real
/// improvement on every other way jev touches the machine.
///
/// **This file deliberately contains no `Input.*` call.** Observing is the
/// whole of the first slice, and "it cannot click anything" is a property worth
/// having by construction rather than by intention. Acting arrives separately,
/// with the guards that belong to it.
public actor WebSession {

    public struct Observation: Sendable {
        public let url: String
        public let title: String
        public let actionCount: Int
        public let omittedActions: Int
        public let textLength: Int
        /// Role and label of each action, in the order the page reports them.
        public let actions: [(id: String, role: String, label: String)]
        /// What the whole payload weighed, which is the number that decides
        /// whether the frame limit is anywhere near being a problem.
        public let payloadBytes: Int
    }

    public enum Failure: Error, Sendable {
        case noSnapshotSource
        case navigationTimedOut
        /// The document went away mid-evaluation, which on a real page usually
        /// means a redirect rather than anything wrong.
        case documentNavigating
        case cdp(CDPClient.Failure)
        case unexpectedReply
    }

    private let client: CDPClient
    private var targetID: String?
    private var sessionID: String?

    public init(endpoint: ChromeDiscovery.Endpoint) {
        self.client = CDPClient(endpoint: endpoint)
    }

    // MARK: - Opening

    /// Open the tab. Backgrounded, so it appears in the tab strip without
    /// stealing focus.
    public func open() async throws {
        try await client.connect()

        let created = try await call("Target.createTarget",
                                     ["url": "about:blank", "background": true])
        guard let targetID = created["targetId"] as? String else { throw Failure.unexpectedReply }
        self.targetID = targetID

        // `flatten` routes every later call by sessionId. It also guarantees an
        // attachedToTarget event on the same socket, which is why CDPClient
        // reads frames in a loop instead of reading one after each send.
        let attached = try await call("Target.attachToTarget",
                                      ["targetId": targetID, "flatten": true])
        guard let sessionID = attached["sessionId"] as? String else { throw Failure.unexpectedReply }
        self.sessionID = sessionID

        // A background tab has no render surface of its own, so geometry and
        // screenshots need one forced. These numbers are the reference
        // implementation's, kept so the viewport culling in snapshot.js sees
        // roughly what it was tuned against.
        try await call("Emulation.setDeviceMetricsOverride",
                       ["width": 1120, "height": 780, "deviceScaleFactor": 1, "mobile": false])
        // Keeps requestAnimationFrame and :focus alive in a tab nobody is
        // looking at, without activating it.
        try await call("Emulation.setFocusEmulationEnabled", ["enabled": true])
    }

    /// Leave the tab open.
    ///
    /// Closing it would erase the evidence. When a task ends — finished,
    /// refused or wrong — the person should be able to look at the page and see
    /// what happened, so only the socket is dropped.
    public func detach() async {
        await client.close()
        targetID = nil
        sessionID = nil
    }

    /// Close the tab as well. For tests and for a task that never rendered
    /// anything worth keeping.
    public func closeTab() async {
        if let targetID {
            _ = try? await call("Target.closeTarget", ["targetId": targetID], useSession: false)
        }
        await detach()
    }

    // MARK: - Navigating

    public func navigate(to url: String, timeout: TimeInterval = 15) async throws {
        try await call("Page.navigate", ["url": url])

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let state = try? await evaluateString("document.readyState"), state == "complete" {
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        throw Failure.navigationTimedOut
    }

    // MARK: - Observing

    /// Run the vendored table builder and report what it saw.
    public func observe() async throws -> Observation {
        guard let source = SnapshotSource.load() else { throw Failure.noSnapshotSource }

        let result = try await call("Runtime.evaluate",
                                    ["expression": source, "returnByValue": true])

        if result["exceptionDetails"] != nil { throw Failure.documentNavigating }
        guard let wrapper = result["result"] as? [String: Any] else { throw Failure.unexpectedReply }
        // snapshot.js returns null before document.body exists.
        guard let value = wrapper["value"] as? [String: Any] else { throw Failure.documentNavigating }

        let rawActions = (value["actions"] as? [[String: Any]]) ?? []
        let actions: [(id: String, role: String, label: String)] = rawActions.map {
            (id: ($0["id"] as? String) ?? "?",
             role: ($0["role"] as? String) ?? ($0["kind"] as? String) ?? "?",
             label: ($0["label"] as? String) ?? "")
        }

        let bytes = (try? JSONSerialization.data(withJSONObject: value).count) ?? 0

        return Observation(
            url: (value["url"] as? String) ?? "",
            title: (value["title"] as? String) ?? "",
            actionCount: actions.count,
            omittedActions: (value["omitted_actions"] as? Int) ?? 0,
            textLength: ((value["text"] as? String) ?? "").count,
            actions: actions,
            payloadBytes: bytes)
    }

    // MARK: -

    @discardableResult
    private func call(_ method: String, _ params: [String: Any] = [:],
                      useSession: Bool = true) async throws -> [String: Any] {
        do {
            return try await client.call(method, params: params,
                                         sessionID: useSession ? sessionID : nil)
        } catch let failure as CDPClient.Failure {
            throw Failure.cdp(failure)
        }
    }

    private func evaluateString(_ expression: String) async throws -> String? {
        let result = try await call("Runtime.evaluate",
                                    ["expression": expression, "returnByValue": true])
        return (result["result"] as? [String: Any])?["value"] as? String
    }
}
