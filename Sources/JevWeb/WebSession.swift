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
/// Acting goes through the DevTools target, not the OS input layer, so a
/// click here is not a click on the Mac. Nothing can be executed that was not
/// in the table the model chose from, and nothing is executed at all until the
/// page has been asked whether it still means what it meant — see `isFresh`.
public actor WebSession {

    public enum Failure: Error, Sendable {
        case noSnapshotSource
        case navigationTimedOut
        /// The document went away mid-evaluation, which on a real page usually
        /// means a redirect rather than anything wrong.
        case documentNavigating
        case cdp(CDPClient.Failure)
        case unexpectedReply
        /// The page changed between reading it and acting on it.
        case pageChanged
        /// The target is gone, hidden, disabled or covered.
        case targetMoved
        /// A dropdown may have half-committed; observe again rather than retry.
        case selectUnconfirmed
        case noTextForFill
    }

    private let client: CDPClient
    private var targetID: String?
    private var sessionID: String?

    public init(endpoint: ChromeDiscovery.Endpoint) {
        self.client = CDPClient(endpoint: endpoint)
    }

    // MARK: - Opening

    /// Make sure there is a live connection and a tab to work in.
    ///
    /// Safe to call before every task, and cheap when nothing has changed:
    /// the connection is verified with one browser-level call and the tab is
    /// only recreated if it has gone. Reconnecting is the expensive part, and
    /// not because of the round trip — Chrome asks the person to allow each
    /// new debugging connection, so a connection opened per task means a
    /// prompt per task, which is not a thing anyone would use.
    public func ensureReady() async throws {
        if sessionID != nil, await isConnectionAlive(), await isTabAlive() { return }

        // Something is gone. Start clean rather than reason about which half.
        await client.close()
        sessionID = nil
        targetID = nil
        try await open()
    }

    /// Whether the socket still answers.
    func isConnectionAlive() async -> Bool {
        (try? await client.call("Browser.getVersion", timeout: 5)) != nil
    }

    /// Whether our tab is still there. The person can close it at any time —
    /// it is a tab in their browser, in their tab strip.
    func isTabAlive() async -> Bool {
        guard targetID != nil, sessionID != nil else { return false }
        return (try? await evaluateString("'ok'")) == "ok"
    }

    /// Open the tab. Backgrounded, so it appears in the tab strip without
    /// stealing focus.
    public func open() async throws {
        do { try await client.connect() }
        catch let failure as CDPClient.Failure { throw Failure.cdp(failure) }

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

    /// Drop the connection.
    ///
    /// Not called between tasks any more — see `ensureReady`. Kept for
    /// shutdown and for tests.
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

    /// Run the vendored table builder.
    public func observe() async throws -> WebSnapshot {
        guard let source = SnapshotSource.load() else { throw Failure.noSnapshotSource }

        let result = try await call("Runtime.evaluate",
                                    ["expression": source, "returnByValue": true])
        if result["exceptionDetails"] != nil { throw Failure.documentNavigating }
        guard let wrapper = result["result"] as? [String: Any] else { throw Failure.unexpectedReply }
        // snapshot.js returns null before document.body exists.
        guard let value = wrapper["value"] as? [String: Any],
              let snapshot = WebSnapshot(value: value) else { throw Failure.documentNavigating }
        return snapshot
    }

    /// The only data-URL prefix the phone will render.
    ///
    /// `web/app.js` refuses a screenshot reference that does not match
    /// `data:image/(png|jpeg|jpg|webp);base64,...`, and refuses it silently —
    /// the card simply appears without the picture. Pinned here and asserted
    /// at launch so changing the capture format cannot quietly remove the one
    /// thing a refusal card exists to show.
    public static let screenshotPrefix = "data:image/jpeg;base64,"

    /// A picture of the tab, as a data URL ready for a card.
    ///
    /// Only taken when a task stops in a way the person needs to see. A
    /// screenshot of a signed-in page is the most revealing thing this backend
    /// can produce, so it is not part of the loop and never goes to a model —
    /// it goes to the phone of the person whose browser it already is.
    public func screenshot() async -> String? {
        guard let result = try? await call("Page.captureScreenshot",
                                           ["format": "jpeg", "quality": 55]),
              let encoded = result["data"] as? String, !encoded.isEmpty else { return nil }
        return Self.screenshotPrefix + encoded
    }

    // MARK: - Acting

    /// Whether the thing we are about to act on still means what it meant.
    ///
    /// The reference implementation compares the whole page here — for a click
    /// its `pageKey` (document, scroll position, viewport, and every input's
    /// value anywhere on the page) and for anything else its `marker`, which
    /// adds the title, six thousand characters of visible text and every
    /// action's semantics. Measured against a real site, that is unusable: a
    /// model call sits between observing and acting, and in those one or two
    /// seconds a page like YouTube scrolls a pixel, swaps a thumbnail or
    /// updates a label. Every decision was then thrown away and remade, and a
    /// three-step task took thirteen — each retry a fresh model call that
    /// often chose differently, so the agent wandered instead of progressing.
    ///
    /// So freshness is asked about the target, not the page: has the document
    /// changed, and does this element's own guard still match. That guard is
    /// not a weak test — it carries the element's identity, role, accessible
    /// name, value, checked/selected/expanded/disabled state, href, and up to
    /// six thousand characters of the text of the form, dialog, row or article
    /// containing it. An element whose surroundings still read the same is the
    /// element that was chosen.
    ///
    /// What this gives up, stated plainly: a change somewhere else on the page
    /// no longer blocks the action. The remaining protections are that guard,
    /// the document check, and the re-resolution in `perform`, which rejects a
    /// target that has moved off screen, become hidden or disabled, or been
    /// covered by something else — with geometry read immediately before the
    /// click rather than taken from the snapshot. That is a judgement about
    /// where the risk actually is, not a proof, and the upstream project says
    /// the same of its own narrower comparison.
    public func isFresh(_ snapshot: WebSnapshot, for action: WebAction?) async -> Bool {
        guard let action, !action.isSynthetic else {
            // Scroll and wait act on the page itself, so there is no target
            // whose meaning could have changed underneath them.
            return true
        }
        // Form control values are the one thing the guard cannot see: they are
        // not part of `innerText`, so a field that reverts or is rewritten
        // under us leaves the surrounding scope byte-identical. That matters
        // for one case in particular — clicking Search or Continue after the
        // site quietly reverted a field, which submits something nobody chose
        // — so the form's values are compared before a click inside a form,
        // and not otherwise.
        let expression = """
        (() => { const c = window.__jevFast;
          if (!c) return null;
          const e = c.nodes.get(\(action.node));
          // Only for a click. The risk this guards against is submitting a
          // form whose other fields changed under us; typing into one field
          // is still the right thing to type whatever happened elsewhere, and
          // comparing the whole form there rejected every TYPE_TEXT on a live
          // page whose own scripts rewrite fields as you use them.
          const form = \(action.kind == "click" ? "e?.closest?.('form')" : "null");
          // Same shape and same identity as snapshot.js's page_key entries,
          // so they compare byte for byte. c.ids.get never allocates, so a
          // field that did not exist at observation time reads undefined and
          // fails the comparison, which is the right answer.
          const fields = form
            ? [...form.querySelectorAll('input,textarea,select')]
                .filter(f => !['password','file','hidden'].includes(f.type))
                .map(f => [c.ids.get(f) ?? null, f.value, f.checked,
                           f.selectedIndex, f.disabled, f.readOnly])
            : [];
          return [performance.timeOrigin, location.href, c.guard(e), fields]; })()
        """
        guard let current = try? await evaluateJSON(expression),
              let parts = current as? [Any], parts.count == 4,
              let token = parts[0] as? Double,
              let href = parts[1] as? String else { return false }

        // A new document invalidates everything: node ids restart at 1 and the
        // indices belong to a page that is gone.
        guard let expected = snapshot.documentToken, token == expected else { return false }
        guard href == snapshot.url else { return false }
        guard let fields = parts[3] as? [[Any]] else { return false }
        for entry in fields {
            guard let id = entry.first as? Int,
                  WebSnapshot.canonical(entry) == snapshot.inputStates[String(id)] else { return false }
        }
        return WebSnapshot.canonical(parts[2]) == snapshot.guards[String(action.node)]
    }

    /// Carry out one action.
    ///
    /// Refuses unless the page is still fresh, and refuses again inside the
    /// page if the target has moved, become hidden or been covered since it
    /// was read. Geometry is resolved immediately before the click rather than
    /// taken from the snapshot, because a scroll between the two would send
    /// the pointer to where the element used to be.
    public func perform(_ action: WebAction, from snapshot: WebSnapshot,
                        text: String? = nil) async throws {
        guard await isFresh(snapshot, for: action) else { throw Failure.pageChanged }

        switch action.kind {
        case "wait":
            // Offered to the model as "wait for the page to update", so it has
            // to be long enough for that to be true. A hundred milliseconds
            // updates nothing, which made WAIT a one-to-two-second model call
            // that reliably changed nothing and could be chosen again forever.
            try? await Task.sleep(nanoseconds: 800_000_000)
            return

        case "scroll":
            // The delta comes from the page's own scroll action rather than a
            // constant duplicated from it. The point is the middle of the
            // forced 1120x780 viewport; if a scrollable sub-element happens to
            // sit under it the wheel moves that instead, which looks like a
            // step that changed nothing.
            try await call("Input.dispatchMouseEvent",
                           ["type": "mouseWheel", "x": 560, "y": 390,
                            "deltaX": 0, "deltaY": action.scrollDelta])
            return

        default:
            break
        }

        // Resolve, re-check and — for a select — commit, in one evaluation.
        // That closes the gap entirely for a select. For a click or a fill the
        // use is one to four CDP round trips later, so a navigation or a
        // layout shift in between can still put the pointer somewhere else:
        // inherent to driving a live page, narrowed rather than closed.
        // Adapted from jev-ultrafast; see THIRD-PARTY-NOTICES.md.
        let payload: [String: Any] = [
            "node": action.node, "kind": action.kind, "value": action.optionValue ?? "",
        ]
        guard let encoded = try? JSONSerialization.data(withJSONObject: payload),
              let literal = String(data: encoded, encoding: .utf8) else {
            throw Failure.unexpectedReply
        }
        let resolve = Self.resolveScript(literal)

        guard let point = try await evaluateJSON(resolve) as? [String: Any],
              let x = point["x"] as? Double, let y = point["y"] as? Double else {
            // Every refusal inside resolveScript happens BEFORE the assignment
            // that fires input/change, so a null return means the dropdown was
            // not touched. This was previously described as half-committed and
            // treated as fatal — the opposite of the truth, and the only case
            // that is perfectly safe to try again.
            throw Failure.targetMoved
        }
        if action.kind == "select" { return }

        for phase in ["mousePressed", "mouseReleased"] {
            try await call("Input.dispatchMouseEvent",
                           ["type": phase, "x": x, "y": y, "button": "left", "clickCount": 1])
        }

        if action.kind == "fill" {
            guard let text else { throw Failure.noTextForFill }
            // Select-all through the browser's own editing command, so the
            // existing contents are replaced rather than appended to.
            try await call("Input.dispatchKeyEvent",
                           ["type": "keyDown", "key": "a", "code": "KeyA",
                            "modifiers": 4, "commands": ["selectAll"]])
            try await call("Input.dispatchKeyEvent",
                           ["type": "keyUp", "key": "a", "code": "KeyA", "modifiers": 4])
            try await call("Input.insertText", ["text": text])
        }
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


    /// The check that runs inside the page immediately before every click.
    ///
    /// Lifted out so it can be asserted on at launch. Three of the refusals
    /// here are the difference between clicking what the model chose and
    /// clicking whatever happens to be on top of it, and one of them —
    /// scrolling the target into view first — is the fix for an agent that
    /// otherwise chooses the only sensible target forever and can never
    /// reach it. Adapted from jev-ultrafast; see THIRD-PARTY-NOTICES.md.
    static func resolveScript(_ actionLiteral: String) -> String {
        """
        (action => {
          const e = window.__jevFast?.nodes.get(action.node);
          if (!e?.isConnected || e.matches(':disabled') ||
              e.closest('[aria-disabled="true"],[inert]') ||
              !e.checkVisibility({checkOpacity:true,checkVisibilityCSS:true})) return null;
          if (action.kind === 'fill' &&
              (e.readOnly || e.getAttribute('aria-readonly') === 'true')) return null;
          // Bring it into view before measuring. A product card taller than
          // the viewport has its centre below the fold, so the bounds check
          // below rejected it forever: the model kept choosing the only
          // sensible target and the executor kept refusing it. macbrow solves
          // this the same way, and issue #3 named it.
          if (typeof e.scrollIntoView === 'function') {
            // 'instant', never the default 'auto'. A page with
            // `scroll-behavior: smooth` animates the default, so the rect read
            // on the next line describes where the element is at the START of
            // the animation. The hit test and the returned point would then
            // both be stale by the time the mouse events arrive three CDP
            // round trips later, and the click lands on whatever scrolled
            // under that point.
            e.scrollIntoView({block: 'center', inline: 'nearest', behavior: 'instant'});
          }
          // getBoundingClientRect forces layout, so this reads the new position.
          const r = e.getBoundingClientRect(), x = r.x + r.width/2, y = r.y + r.height/2;
          if (!r.width || !r.height || x < 0 || y < 0 || x >= innerWidth || y >= innerHeight) return null;
          // Hit-test what is actually at that point. A sticky header or a
          // cookie bar sitting over the target means clicking would hit that
          // instead, which is how an agent "clicks" something it never touched.
          if (!e.contains(document.elementFromPoint(x, y))) return null;
          if (action.kind === 'select') {
            if (e.tagName !== 'SELECT' || ![...e.options].some(o => o.value === action.value &&
                !o.disabled && !o.closest('optgroup[disabled]'))) return null;
            e.value = action.value;
            e.dispatchEvent(new Event('input', {bubbles:true}));
            e.dispatchEvent(new Event('change', {bubbles:true}));
          }
          return {x, y};
        })(\(actionLiteral))
        """
    }

    private func evaluateJSON(_ expression: String) async throws -> Any? {
        let result = try await call("Runtime.evaluate",
                                    ["expression": expression, "returnByValue": true])
        if result["exceptionDetails"] != nil { throw Failure.documentNavigating }
        return (result["result"] as? [String: Any])?["value"]
    }

    private func evaluateString(_ expression: String) async throws -> String? {
        let result = try await call("Runtime.evaluate",
                                    ["expression": expression, "returnByValue": true])
        return (result["result"] as? [String: Any])?["value"] as? String
    }
}
