import Foundation
import JevCore

/// The one place a web task generates text rather than choosing from a list.
///
/// Everything else the browser backend does is a choice between options the
/// code already owns: this element or that one, click or scroll, done or
/// blocked. Filling a field is the exception — the value has to be written, and
/// no list of candidates can contain it.
///
/// That is a real widening of what the model can cause, so it is kept as narrow
/// as it can be made:
///
/// - It runs through the local gateway on loopback, not a vendor's endpoint, so
///   there is no second credential and no second outbound relationship. The
///   gateway holds the provider keys and records what was spent.
/// - The reply must be a JSON object with exactly one usable `text`. A reply
///   that is nearly right is refused rather than salvaged — no scraping a
///   quoted string out of prose, because a model that answered in the wrong
///   shape has not demonstrated it understood the question.
/// - No CONTENT here is logged. The page context that goes up contains
///   whatever the person was looking at, and the answer is about to be typed
///   somewhere, so neither the goal, the field, the page title, the current
///   value nor the reply ever reaches a log line. What is recorded is which
///   model was asked, whether it answered, and how long it took — see `log`.
///   That is a setting and a timing, not a thing anybody was reading.
public enum WebTextModel {

    public enum Failure: Error, Sendable, Equatable {
        case noKey
        case transport(String)
        case http(Int)
        /// The reply parsed, but not into one usable value.
        case unusableReply
    }

    /// Where the gateway listens. Loopback by default: this is a local service,
    /// and a web task's page context should not leave the machine by accident
    /// because an environment variable was mistyped.
    public static var baseURL: URL {
        if let raw = Allowly.environment("ALLOWLY_WEB_TEXT_BASE_URL", "JEV_WEB_TEXT_BASE_URL"),
           let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           url.scheme != nil {
            return url
        }
        return URL(string: "http://127.0.0.1:29080")!
    }

    /// What the model is when nobody has said otherwise.
    ///
    /// The route is in passthrough mode, so a concrete name is honoured rather
    /// than reclassified. Named explicitly instead of using a virtual `oag/*`
    /// rung, because which model writes into a form field is a decision worth
    /// being able to point at.
    public static let defaultModel = "openai/gpt-5.6-luna"

    /// What the menu bar has been told to use, when anything.
    ///
    /// JevWeb cannot see jevd, so the daemon hands the lookup in at startup —
    /// the hook shape `CuaDriver.log` and `DecisionCache.log` already use.
    /// Unset in a test or a bare library run, and then the environment and the
    /// default answer exactly as they did before.
    nonisolated(unsafe) public static var storedChoice: (@Sendable () -> String?)?

    /// Where a one-line record of each request goes, if anywhere.
    ///
    /// The menu can say which model is selected; only this can say which model
    /// actually served a task. Without it, "grok wrote that one" is a claim
    /// about a setting rather than evidence about a request — and the setting
    /// can change between the task starting and anybody asking.
    ///
    /// Same shape as `storedChoice` and `CuaDriver.log`: JevWeb cannot see the
    /// daemon, so the daemon hands the writer in. Unset in a library run, and
    /// then nothing is written, exactly as before.
    ///
    /// **What it may be given.** The model id, the outcome, and the elapsed
    /// time. Never the goal, the field label, the page title, the value that
    /// was there or the value that came back — those are the page, and the
    /// page is not ours to write down.
    nonisolated(unsafe) public static var log: (@Sendable (String) -> Void)?

    /// The stored choice wins over the environment, which is the reverse of
    /// `loadAPIKey` below and deliberate: `open` inherits no shell, so for the
    /// installed app the environment is never set and a menu the person
    /// clicked has to be what takes effect.
    ///
    /// Pure, so the precedence is a launch assertion rather than a claim — and
    /// so the menu bar can show the same answer the request will use by
    /// calling the same function instead of a second copy of the rule. Two
    /// copies agreed on the day they were written and would have drifted.
    ///
    /// An empty or blank string is not a choice.
    public static func effective(stored: String?, environment: String?) -> String {
        if let stored = stored?.trimmingCharacters(in: .whitespacesAndNewlines),
           !stored.isEmpty {
            return stored
        }
        if let environment = environment?.trimmingCharacters(in: .whitespacesAndNewlines),
           !environment.isEmpty {
            return environment
        }
        return defaultModel
    }

    /// The environment half of the rule, in one place.
    ///
    /// `Allowly.environment` takes both spellings; reading the raw dictionary
    /// for the new name only — as the menu first did — makes the menu label
    /// and the log disagree with the request on a machine that still sets
    /// `JEV_WEB_TEXT_MODEL`.
    public static var modelFromEnvironment: String? {
        Allowly.environment("ALLOWLY_WEB_TEXT_MODEL", "JEV_WEB_TEXT_MODEL")
    }

    public static var model: String {
        effective(stored: storedChoice?(), environment: modelFromEnvironment)
    }

    /// The gateway key. Same shape as `JevAPI.loadAPIKey`, and for the same
    /// reason: `open` does not inherit a shell environment, so the file is the
    /// path that actually works when Jev.app is launched normally.
    public static func loadAPIKey() -> String? {
        if let fromEnv = Allowly.environment("ALLOWLY_OAG_API_KEY", "JEV_OAG_API_KEY"),
           !fromEnv.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fromEnv.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let url = Allowly.supportDirectory.appendingPathComponent("oag-api-key")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - The reply

    /// The single value a reply is allowed to carry.
    ///
    /// Deliberately strict. `{"text": "cat"}` is the only shape that means
    /// anything; everything else — a missing key, a number, a nested object, a
    /// second field, an empty string — is a refusal. Pure, so every one of
    /// those cases is a launch assertion rather than a hope.
    public static func value(fromReply json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root.count == 1,
              let text = root["text"] as? String
        else { return nil }
        // A field filled with nothing is not a filled field, and whitespace
        // would be typed as-is.
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// Pull the assistant's answer out of a Chat Completions body.
    ///
    /// Reads `content` by name. A reasoning model returns `reasoning_content`
    /// alongside it — gpt-5.6-luna and grok-4.6 both do — and taking "the first
    /// string in the message" would type the model's private deliberation into
    /// someone's search box.
    public static func content(fromBody data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else { return nil }
        return content
    }

    // MARK: - The request

    /// What to write into one field.
    ///
    /// `response_format: json_object` is deliberately NOT sent. It buys nothing
    /// — the reply is validated here either way — and it costs three ways: the
    /// gateway refuses it outright for an Anthropic upstream, OpenAI's Responses
    /// translation rejects any request whose *input* messages lack the literal
    /// word "json", and it measured slower. Validating our own reply is the
    /// thing that actually holds.
    /// `model` is passed in rather than read here, so the caller resolves it
    /// once and the id it logs is the id in the body — not a second read that
    /// could land after the menu changed.
    public static func body(goal: String, fieldLabel: String, fieldRole: String,
                            currentValue: String, pageTitle: String,
                            model: String = WebTextModel.model) -> [String: Any] {
        [
            "model": model,
            "max_tokens": 1024,
            "reasoning": ["effort": "low"],
            "messages": [
                ["role": "system",
                 "content": """
                 You supply the value for one form field on a web page.
                 Reply with a JSON object of exactly one key, "text", whose value \
                 is the string to type. Nothing else.
                 Write only what the goal asks for. Do not invent dates, \
                 quantities, addresses or payment details.
                 """],
                ["role": "user",
                 "content": """
                 Goal: \(goal)
                 Field: \(fieldLabel) (\(fieldRole))
                 Current value: \(currentValue.isEmpty ? "(empty)" : currentValue)
                 Page: \(pageTitle)
                 """],
            ],
        ]
    }

    /// The one line a request is allowed to leave behind.
    ///
    /// Pure, so what it says is a launch assertion. More to the point, its
    /// SIGNATURE is the protection: it takes a model, an outcome and a
    /// duration, and there is no parameter a goal, a field label, a page title
    /// or a typed value could arrive through. No assertion enforces that —
    /// a test cannot see a future edit that adds an argument — but the shape
    /// means such an edit has to be deliberate and visible in review.
    static func record(model: String, outcome: String, seconds: TimeInterval) -> String {
        "[allowly] web text: \(model) \(outcome) in \(String(format: "%.1f", seconds))s"
    }

    /// Ask for the value. Returns the string to type, or why it cannot.
    public static func text(goal: String, fieldLabel: String, fieldRole: String,
                            currentValue: String, pageTitle: String) async -> Result<String, Failure> {
        // Resolved once. Everything below — the body, the log line — uses this
        // one value, so the record cannot name a different model than the one
        // that was asked.
        let asked = model
        let started = Date()
        // Named `note` and not `record`, so it does not shadow the pure
        // builder it calls.
        func note(_ outcome: String) {
            log?(record(model: asked, outcome: outcome,
                        seconds: Date().timeIntervalSince(started)))
        }

        guard let key = loadAPIKey() else {
            note("had no gateway key")
            return .failure(.noKey)
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        guard let encoded = try? JSONSerialization.data(
            withJSONObject: body(goal: goal, fieldLabel: fieldLabel, fieldRole: fieldRole,
                                 currentValue: currentValue, pageTitle: pageTitle,
                                 model: asked))
        else {
            note("could not be asked — the request would not encode")
            return .failure(.unusableReply)
        }
        request.httpBody = encoded

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // The message is the transport's, never the request: the body holds
            // the page the person was looking at.
            note("did not answer")
            return .failure(.transport(error.localizedDescription))
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            note("was refused by the gateway (HTTP \(http.statusCode))")
            return .failure(.http(http.statusCode))
        }
        guard let reply = content(fromBody: data), let value = value(fromReply: reply) else {
            // Not the reply itself. A model that answers in the wrong shape is
            // worth knowing about; what it actually said is still the page.
            note("answered in a shape that could not be used")
            return .failure(.unusableReply)
        }
        note("filled a field")
        return .success(value)
    }
}
