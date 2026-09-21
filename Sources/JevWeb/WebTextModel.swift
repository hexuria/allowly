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
/// - Nothing here is logged. The page context that goes up contains whatever
///   the person was looking at, and the answer is about to be typed somewhere.
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

    /// The route is in passthrough mode, so a concrete name is honoured rather
    /// than reclassified. Named explicitly instead of using a virtual `oag/*`
    /// rung, because which model writes into a form field is a decision worth
    /// being able to point at.
    public static var model: String {
        return Allowly.environment("ALLOWLY_WEB_TEXT_MODEL", "JEV_WEB_TEXT_MODEL")
            ?? "openai/gpt-5.6-luna"
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
    public static func body(goal: String, fieldLabel: String, fieldRole: String,
                            currentValue: String, pageTitle: String) -> [String: Any] {
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

    /// Ask for the value. Returns the string to type, or why it cannot.
    public static func text(goal: String, fieldLabel: String, fieldRole: String,
                            currentValue: String, pageTitle: String) async -> Result<String, Failure> {
        guard let key = loadAPIKey() else { return .failure(.noKey) }

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        guard let encoded = try? JSONSerialization.data(
            withJSONObject: body(goal: goal, fieldLabel: fieldLabel, fieldRole: fieldRole,
                                 currentValue: currentValue, pageTitle: pageTitle))
        else { return .failure(.unusableReply) }
        request.httpBody = encoded

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // The message is the transport's, never the request: the body holds
            // the page the person was looking at.
            return .failure(.transport(error.localizedDescription))
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            return .failure(.http(http.statusCode))
        }
        guard let reply = content(fromBody: data), let value = value(fromReply: reply) else {
            return .failure(.unusableReply)
        }
        return .success(value)
    }
}
