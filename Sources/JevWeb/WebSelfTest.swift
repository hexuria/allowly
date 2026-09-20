import Foundation

/// Checks that run at every launch, none of which need a browser.
///
/// The pattern is the one the rest of jev uses: a safety rule that is only
/// written down in a comment erodes, so every rule that matters is a failing
/// assertion the moment it stops being true.
public enum WebSelfTest {

    public static func run() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append("web: \(name)") }
        }

        checkActivePortParser(check)
        checkToggleState(check)
        checkVersionPayload(check)
        checkExplanations(check)
        checkSnapshotResource(check)
        checkEndpointNeverPrintsCredential(check)
        checkTextModelReply(check)
        checkStartResolution(check)
        checkSoundness(check)
        checkActionSpace(check)
        checkStandingRules(check)
        checkResolveScript(check)

        return failures
    }

    // MARK: -

    private static func checkActivePortParser(_ check: (String, Bool) -> Void) {
        // Chrome writes the second line WITHOUT a trailing newline, so that is
        // the shape to test; the terminated variant is the one that does not
        // occur in the wild.
        let good = ChromeDiscovery.parseActivePort("9222\n/devtools/browser/2f1a-4b")
        check("the unterminated file Chrome actually writes parses", good?.port == 9222)
        check("and keeps the path", good?.path == "/devtools/browser/2f1a-4b")
        check("a trailing newline is tolerated too",
              ChromeDiscovery.parseActivePort("9222\n/devtools/browser/2f1a-4b\n")?.port == 9222)

        // Chrome writes the path on the second line. Without it the WebSocket
        // upgrade 404s, so a one-line file must not produce a usable-looking
        // endpoint — this is the difference between a clear failure and a hang.
        check("a one-line port file is refused",
              ChromeDiscovery.parseActivePort("9222") == nil)
        check("an empty file is refused",
              ChromeDiscovery.parseActivePort("") == nil)
        check("a non-numeric port is refused",
              ChromeDiscovery.parseActivePort("nine\n/devtools/browser/x") == nil)
        check("port zero is refused",
              ChromeDiscovery.parseActivePort("0\n/devtools/browser/x") == nil)
        check("a port above the range is refused",
              ChromeDiscovery.parseActivePort("70000\n/devtools/browser/x") == nil)

        // A stale or truncated file must not turn into a request to whatever
        // path happened to be on line two.
        check("a path outside /devtools/browser/ is refused",
              ChromeDiscovery.parseActivePort("9222\n/evil") == nil)
        check("a bare /devtools/browser/ with no id is refused",
              ChromeDiscovery.parseActivePort("9222\n/devtools/browser/") == nil)

        check("surrounding whitespace does not defeat the parse",
              ChromeDiscovery.parseActivePort(" 9222 \n /devtools/browser/x \n")?.port == 9222)
    }

    private static func checkToggleState(_ check: (String, Bool) -> Void) {
        check("an enabled toggle reads true",
              ChromeDiscovery.toggleState(
                localState: #"{"devtools":{"remote_debugging":{"user-enabled":true}}}"#) == true)
        check("a disabled toggle reads false",
              ChromeDiscovery.toggleState(
                localState: #"{"devtools":{"remote_debugging":{"user-enabled":false}}}"#) == false)

        // Three-valued on purpose: "never recorded" is not "off", and telling
        // someone to untick something they never ticked is a worse message.
        check("an absent setting reads as unknown",
              ChromeDiscovery.toggleState(localState: #"{"devtools":{}}"#) == nil)
        check("an empty object reads as unknown",
              ChromeDiscovery.toggleState(localState: "{}") == nil)
        check("malformed JSON reads as unknown",
              ChromeDiscovery.toggleState(localState: "not json") == nil)
    }

    private static func checkVersionPayload(_ check: (String, Bool) -> Void) {
        func payload(_ json: String) -> URL? {
            ChromeDiscovery.parseVersionPayload(Data(json.utf8))
        }

        // Preferred over the path in DevToolsActivePort, because Chrome leaves
        // that file behind when it is relaunched on the same port with a
        // different --user-data-dir, and the stale id in it passes every local
        // check and then 404s on the upgrade.
        check("a version payload yields the live socket URL",
              payload(#"{"webSocketDebuggerUrl":"ws://127.0.0.1:9222/devtools/browser/abc"}"#)?.absoluteString
                == "ws://127.0.0.1:9222/devtools/browser/abc")
        check("localhost is accepted as well as the literal address",
              payload(#"{"webSocketDebuggerUrl":"ws://localhost:9222/devtools/browser/abc"}"#) != nil)

        // Chrome tells us where to connect, but that is not a reason to connect
        // anywhere it says.
        check("a payload naming another host is refused",
              payload(#"{"webSocketDebuggerUrl":"ws://evil.example/devtools/browser/abc"}"#) == nil)
        check("a non-websocket scheme is refused",
              payload(#"{"webSocketDebuggerUrl":"http://127.0.0.1:9222/x"}"#) == nil)
        check("a payload without the key is refused",
              payload(#"{"Browser":"Chrome/153.0.0.0"}"#) == nil)
        check("a malformed payload is refused", payload("not json") == nil)
    }

    private static func checkExplanations(_ check: (String, Bool) -> Void) {
        // Each state gets its own sentence because each one needs a different
        // action. Telling someone to restart Chrome when the real answer is
        // "accept the prompt already on your screen" costs them every open tab.
        let consent = ChromeDiscovery.explain(.consentPending)
        let notListening = ChromeDiscovery.explain(.notListening)
        let off = ChromeDiscovery.explain(.toggleOff)
        let never = ChromeDiscovery.explain(.neverEnabled)

        check("a pending consent prompt does not tell anyone to restart Chrome",
              !consent.lowercased().contains("restart"))
        check("a pending consent prompt says to accept it",
              consent.lowercased().contains("accept"))
        check("a dead port is the one case that asks for a restart",
              notListening.lowercased().contains("restart"))
        check("an off toggle names the page that turns it on",
              off.contains("chrome://inspect"))
        check("a never-set toggle names the checkbox by its wording",
              never.contains("Allow remote debugging for this browser instance"))

        // Distinct states must not collapse into the same sentence, or the
        // person is told to do the wrong thing half the time.
        check("the four failure sentences are all different",
              Set([consent, notListening, off, never]).count == 4)
    }

    private static func checkSnapshotResource(_ check: (String, Bool) -> Void) {
        guard let source = snapshotJS else {
            check("snapshot.js is bundled", false)
            return
        }
        check("snapshot.js is bundled", true)
        check("snapshot.js is not empty", source.count > 1000)

        // The safety-critical line. snapshot.js decides what a model is allowed
        // to see, and it excludes password, file and hidden inputs at source —
        // which is why "never type into a password field" is structural here
        // rather than a rule applied afterwards. A careless re-vendor that drops
        // this must fail at launch, not in front of a login form.
        check("snapshot.js still excludes password, file and hidden inputs",
              source.contains("['password','file','hidden'].includes(e.type)"))

        // It is interpolated into a larger expression as well as evaluated on
        // its own, so it has to be an expression. A line comment at the top
        // would silently comment out the rest of that expression.
        check("snapshot.js is an expression, not a statement",
              source.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("(()"))
        check("snapshot.js has no leading line comment",
              !source.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("//"))
    }

    private static func checkEndpointNeverPrintsCredential(_ check: (String, Bool) -> Void) {
        let secret = "/devtools/browser/de1e7e-d0-n0t-l0g"
        let endpoint = ChromeDiscovery.Endpoint(
            port: 9222,
            webSocketURL: URL(string: "ws://127.0.0.1:9222\(secret)")!,
            profileDirectory: URL(fileURLWithPath: "/tmp"))

        // The WebSocket path is the entire authentication story for CDP: it is
        // a bearer credential for a signed-in browser. Describing an endpoint
        // happens in log lines and on cards, so describing one must not leak it.
        check("an endpoint description omits the credential",
              !endpoint.description.contains(secret))
        check("an endpoint description omits the word devtools entirely",
              !endpoint.description.contains("devtools"))
        check("an endpoint still says something useful",
              endpoint.description.contains("9222"))
    }

    private static func checkTextModelReply(_ check: (String, Bool) -> Void) {
        let value = WebTextModel.value(fromReply:)

        check("a well-formed reply yields its value",
              value(#"{"text":"coffee filters"}"#) == "coffee filters")

        // Refuse rather than salvage. A model that answered in the wrong shape
        // has not shown it understood the question, and the value is about to
        // be typed into a real page.
        check("prose around the answer is refused",
              value(#"Sure! Here you go: {"text":"coffee filters"}"#) == nil)
        check("a missing key is refused", value(#"{"value":"coffee filters"}"#) == nil)
        check("a non-string value is refused", value(#"{"text":42}"#) == nil)
        check("a nested object is refused", value(#"{"text":{"v":"x"}}"#) == nil)
        check("an extra key is refused — one question, one answer",
              value(#"{"text":"x","confidence":0.9}"#) == nil)
        check("an empty string is refused", value(#"{"text":""}"#) == nil)
        check("whitespace only is refused", value(#"{"text":"   "}"#) == nil)
        check("a bare string is refused", value(#""coffee filters""#) == nil)
        check("malformed JSON is refused", value("not json at all") == nil)

        // A reasoning model returns its deliberation beside the answer. Taking
        // the first string in the message would type that into a search box.
        let withReasoning = Data(#"""
        {"choices":[{"message":{"role":"assistant",
         "reasoning_content":"The user wants me to reply with json.",
         "content":"{\"text\":\"coffee filters\"}"}}]}
        """#.utf8)
        check("the answer is read from content, never from reasoning_content",
              WebTextModel.content(fromBody: withReasoning) == #"{"text":"coffee filters"}"#)

        let reasoningOnly = Data(#"{"choices":[{"message":{"reasoning_content":"thinking"}}]}"#.utf8)
        check("a message with only reasoning yields nothing",
              WebTextModel.content(fromBody: reasoningOnly) == nil)
        check("an error body yields nothing",
              WebTextModel.content(fromBody: Data(#"{"type":"error"}"#.utf8)) == nil)

        // response_format is deliberately absent: the gateway refuses it for an
        // Anthropic upstream, and OpenAI's Responses translation rejects any
        // request whose input messages lack the literal word "json".
        let request = WebTextModel.body(goal: "search for coffee filters",
                                        fieldLabel: "Search", fieldRole: "searchbox",
                                        currentValue: "", pageTitle: "Amazon.com")
        check("the request does not ask for a constrained response format",
              request["response_format"] == nil)
        check("the request names a model", (request["model"] as? String)?.isEmpty == false)
    }

    private static func checkStartResolution(_ check: (String, Bool) -> Void) {
        let resolve = WebStart.resolve(goal:currentHost:)

        check("a named site starts there",
              resolve("play blinding lights on youtube", nil) == .url("https://www.youtube.com/"))
        check("the name may appear anywhere in the sentence",
              resolve("on amazon search for coffee filters", nil) == .url("https://www.amazon.com/"))
        check("a dotted spelling still names the site",
              resolve("go to youtube.com and play something", nil) == .url("https://www.youtube.com/"))

        // Longest first, or a two-word name loses to a one-word one inside it.
        check("a two-word site name is not beaten by a shorter match",
              resolve("search stack overflow for actor reentrancy", nil)
                == .url("https://stackoverflow.com/"))

        // Substring matching would fire on a hostile page title the goal quoted.
        check("a site name inside another word does not count",
              resolve("read about amazonian rainforests", "en.wikipedia.org") == .currentTab)

        // Said while looking at something, with no site named, means this page.
        check("no site named but a page open means that page",
              resolve("open the first result", "duckduckgo.com") == .currentTab)

        // The refusal. Guessing a URL is the one thing that must not happen —
        // it is exactly the freedom withheld from the model everywhere else.
        check("no site and no open page is a refusal, not a guess",
              resolve("open the first result", nil) == .unknown)
        check("an empty goal with nothing open is a refusal",
              resolve("", nil) == .unknown)
        check("the refusal says what to do instead",
              WebStart.cannotStart.contains("open the page first"))

        // Every entry has to be something a person can read on a card.
        check("every known site is an https URL",
              WebStart.knownSites.allSatisfy { $0.url.hasPrefix("https://") })
        check("no known site name is empty",
              WebStart.knownSites.allSatisfy { !$0.spoken.isEmpty })
    }

    private static func checkSoundness(_ check: (String, Bool) -> Void) {
        let offered: Set<String> = ["1", "2", "3"]
        func sound(_ choice: String, _ confidence: Double, _ p: [String: Double],
                   _ options: Set<String> = offered) -> Bool {
            WebChoice.isSound(choice: choice, confidence: confidence,
                              probabilities: p, offered: options)
        }

        check("a well-formed answer is sound",
              sound("2", 0.8, ["1": 0.1, "2": 0.8, "3": 0.1]))

        // Six rules, each with a way of being wrong that does not look wrong.
        check("a choice outside the offered set is refused",
              !sound("9", 0.9, ["1": 0.1, "2": 0.8, "3": 0.1]))
        check("a distribution over different keys is refused",
              !sound("2", 0.9, ["1": 0.5, "2": 0.5]))
        check("a distribution with an extra key is refused",
              !sound("2", 0.9, ["1": 0.1, "2": 0.7, "3": 0.1, "9": 0.1]))
        check("probabilities that do not sum to one are refused",
              !sound("2", 0.9, ["1": 0.1, "2": 0.2, "3": 0.1]))
        check("a probability outside zero to one is refused",
              !sound("2", 0.9, ["1": -0.1, "2": 1.05, "3": 0.05]))
        check("a non-finite number is refused",
              !sound("2", .nan, ["1": 0.1, "2": 0.8, "3": 0.1]))
        check("an infinite probability is refused",
              !sound("2", 0.9, ["1": .infinity, "2": 0.8, "3": 0.1]))
        check("an argmax disagreeing with the choice is refused",
              !sound("1", 0.9, ["1": 0.1, "2": 0.8, "3": 0.1]))

        // A tie is genuinely the argmax, so it passes; the tolerance exists
        // because the sum check already allows 0.02 of drift.
        check("a tie at the top is allowed",
              sound("1", 0.5, ["1": 0.5, "2": 0.5, "3": 0.0], ["1", "2", "3"]))
        check("an empty option set is refused",
              !sound("1", 1.0, [:], []))

        // Soundness is not conviction, and conviction cannot be a flat
        // probability. Measured: picking one element out of sixty at p=0.3 is
        // a strong, correct answer; a 0.6 floor rejected it and reported a
        // finished task as stuck.
        let wide = Dictionary(uniqueKeysWithValues: (1...60).map {
            (String($0), $0 == 1 ? 0.3 : 0.7 / 59)
        })
        // The floor has to behave the same at both ends. Relative-to-uniform
        // does not: it cannot exceed 2.0 with two options, so a 98-to-2 call
        // would have failed a 2.0 bar. This assertion caught exactly that.
        check("a clear winner among many is strong",
              (WebChoice.strength(choice: "1", probabilities: wide) ?? 0) > 2)
        check("a near-even spread is not",
              (WebChoice.strength(choice: "1", probabilities:
                Dictionary(uniqueKeysWithValues: (1...60).map { (String($0), 1.0 / 60) })) ?? 0) < 2)
        check("a coin flip between two is not",
              (WebChoice.strength(choice: "1", probabilities: ["1": 0.51, "2": 0.49]) ?? 0) < 2)
        check("a decisive pick between two is",
              (WebChoice.strength(choice: "1", probabilities: ["1": 0.98, "2": 0.02]) ?? 0) > 2)
        check("a single option has no strength to measure",
              WebChoice.strength(choice: "1", probabilities: ["1": 1.0]) == nil)
    }

    private static func checkActionSpace(_ check: (String, Bool) -> Void) {
        func action(_ json: [String: Any]) -> WebAction? { WebAction(json: json) }

        // One node that can be both typed into and clicked — snapshot.js emits
        // two rows for exactly this — must still be one element with one index,
        // offered under both operations. Two indices for one box is how a
        // model ends up typing into the thing it meant to click.
        let both = [
            action(["id": "e1", "kind": "fill", "node": 7, "role": "searchbox",
                    "label": "Search", "value": ""]),
            action(["id": "e2", "kind": "click", "node": 7, "role": "searchbox",
                    "label": "Open Search", "value": ""]),
            action(["id": "e3", "kind": "click", "node": 9, "role": "button", "label": "Go"]),
        ].compactMap { $0 }
        let space = ActionSpace(actions: both)

        check("one node gets one index however many ways it can be used",
              space.elements.count == 2)
        check("and is offered under both operations",
              space.elements.first?.operations.sorted() == ["CLICK", "TYPE_TEXT"])
        check("typing targets the shared index",
              space.action(operation: "TYPE_TEXT", target: "1")?.node == 7)
        check("clicking targets it too",
              space.action(operation: "CLICK", target: "1")?.node == 7)

        // The refusal that matters: an index the model invented, or one that
        // belongs to a different operation, resolves to nothing.
        check("an invented index resolves to nothing",
              space.action(operation: "CLICK", target: "99") == nil)
        check("a target valid for another operation is not borrowed",
              space.action(operation: "TYPE_TEXT", target: "2") == nil)
        check("an unknown operation resolves to nothing",
              space.action(operation: "DELETE", target: "1") == nil)

        // Page-level controls are keyed by the name the model is shown.
        let withScroll = ActionSpace(actions: [
            action(["id": "scroll_down", "kind": "scroll", "label": "Scroll down", "delta": 560]),
            action(["id": "wait", "kind": "wait", "label": "Wait"]),
        ].compactMap { $0 })
        check("page-level controls are offered by name",
              withScroll.controls["SCROLL_DOWN"] != nil && withScroll.controls["WAIT"] != nil)
        check("page-level controls are not elements",
              withScroll.elements.isEmpty)
        check("the scroll delta comes from the page",
              withScroll.controls["SCROLL_DOWN"]?.scrollDelta == 560)

        // The table builder is vendored and tracks upstream. A kind this code
        // cannot carry out must be dropped, not offered: as a control it would
        // reach the model with no target check and then fall through to the
        // click path.
        let unknown = ActionSpace(actions: [
            action(["id": "teleport", "kind": "teleport", "label": "Teleport"]),
        ].compactMap { $0 })
        check("an unknown kind is dropped, not offered as a control",
              unknown.controls.isEmpty && unknown.elements.isEmpty)

        // A dropdown's options are code-owned: the model picks "1:2" and which
        // option that is was decided here, not there.
        let dropdown = ActionSpace(actions: [
            action(["id": "e1", "kind": "select", "node": 3, "role": "combobox",
                    "label": "Country → Japan", "value": "JP", "current_value": "France"]),
            action(["id": "e2", "kind": "select", "node": 3, "role": "combobox",
                    "label": "Country → Peru", "value": "PE", "current_value": "France"]),
        ].compactMap { $0 })
        check("a dropdown is one element", dropdown.elements.count == 1)
        check("labelled by the control, not the option",
              dropdown.elements.first?.label == "Country")
        check("showing what is currently selected",
              dropdown.elements.first?.value == "France")
        check("with one target per option",
              dropdown.action(operation: "SELECT", target: "1:1")?.optionValue == "JP"
                && dropdown.action(operation: "SELECT", target: "1:2")?.optionValue == "PE")
    }

    private static func checkStandingRules(_ check: (String, Bool) -> Void) {
        let rules = WebChoice.rules.lowercased()

        // Page content is attacker-controlled and becomes part of the model's
        // premise. This line does not solve that, and nothing here does — but
        // removing it should be a decision someone makes on purpose.
        check("the rules tell the model the page is data, not instructions",
              rules.contains("never a command"))
        check("the rules refuse checkout", rules.contains("check out"))
        check("the rules refuse signing in", rules.contains("do not sign in"))
        check("the rules refuse passwords and codes",
              rules.contains("password") && rules.contains("verification code"))
        check("the rules refuse consent banners", rules.contains("cookie banner"))
        check("the rules forbid inventing values", rules.contains("do not invent"))

        // Measured: an Amazon results page reported a refusal because the
        // results were below the fold. Looking before concluding is the fix.
        check("the rules say to scroll before concluding", rules.contains("scroll"))

        // "I will not" and "I could not" mean opposite things to the person
        // waiting, and collapsing them reported one as the other.
        check("refusing and being stuck are separate answers",
              rules.contains("blocked") && rules.contains("stuck"))
    }

    private static func checkResolveScript(_ check: (String, Bool) -> Void) {
        let script = WebSession.resolveScript("{\"node\":1}")

        // Read geometry fresh, after bringing the target into view. A card
        // taller than the viewport has its centre below the fold, and without
        // this the executor refuses the only sensible target forever while the
        // model keeps choosing it.
        check("the target is scrolled into view before measuring",
              script.contains("scrollIntoView"))
        // Force-unwrapping here would trap the daemon at launch instead of
        // reporting the very failure the line above just recorded.
        if let scrolled = script.range(of: "scrollIntoView"),
           let measured = script.range(of: "getBoundingClientRect") {
            check("geometry is read after that scroll", scrolled.upperBound < measured.lowerBound)
        } else {
            check("geometry is read after that scroll", false)
        }
        // An animated scroll would make that measurement describe where the
        // element was, not where it lands.
        check("the scroll is instant, not animated", script.contains("behavior: 'instant'"))

        // Hit-testing is what stops a click landing on a sticky header or a
        // cookie bar covering the target.
        check("what is actually at the point is hit-tested",
              script.contains("elementFromPoint"))
        check("a disconnected target is refused", script.contains("isConnected"))
        check("a disabled target is refused", script.contains(":disabled"))
        check("an invisible target is refused", script.contains("checkVisibility"))
        check("a read-only field is not typed into", script.contains("readOnly"))
        check("the action literal is interpolated in",
              script.contains("{\"node\":1}"))
    }

    /// The vendored table builder. See THIRD-PARTY-NOTICES.md.
    static var snapshotJS: String? { SnapshotSource.load() }
}
