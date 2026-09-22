import Foundation
import JevCore

/// The TypeSafe System One HTTP API, as it actually is.
///
/// Verified against the official Rust SDK (typesafe-sdk 0.1.2) and a live call:
///   POST https://api.typesafe.ai/v1/systemone
///   Authorization: Bearer <key>
///   { "state": <any json>, "model": "jev-latest", "questions": { name: question } }
/// A question is {"type":"choice","instructions":...,"criteria":{label: null,…}}
/// or {"type":"noul","instructions":...}. Answers come back as
///   { "answers": { name: {"type":"choice","choice":…,"confidence":…,"probabilities":{…}} } }
///
/// The previous version guessed api.typesafe.dev/v1/decide with an X-API-Key
/// header — wrong host, wrong path, wrong auth — and had never been run.
public enum JevAPI {
    static let directEndpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!

    /// Where decisions are sent.
    ///
    /// Overridable so the traffic can be put behind something local that
    /// strips personal data out of it first. It is worth saying why that is
    /// wanted: a browser task sends the page's text and every control's label
    /// on each step, and on a signed-in page those labels are not neutral —
    /// measured on a real Amazon page, element 2 read "Deliver to <name>,
    /// <city> <postcode>" and element 7 "Hello, <name>". That went to a
    /// vendor, up to a hundred and twenty times a task.
    ///
    /// Loopback only. This decides where a page someone is signed into gets
    /// sent, so a mistyped variable must not be able to send it somewhere
    /// else — anything that is not a local address is ignored and the direct
    /// endpoint is used.
    public static var endpoint: URL {
        guard let raw = Allowly.environment("ALLOWLY_DECIDE_BASE_URL", "JEV_DECIDE_BASE_URL"),
              let url = URL(string: raw.hasSuffix("/") ? raw + "v1/systemone"
                                                       : raw + "/v1/systemone"),
              isLoopback(url)
        else { return directEndpoint }
        return url
    }

    /// Whether a URL points at this machine and nowhere else.
    ///
    /// Pure, and asserted at launch: the whole value of the override is that
    /// it cannot widen where data goes.
    /// Forwards to `Allowly.isLoopback`, which the voice transcriber now uses
    /// too. One implementation, so the two cannot drift into disagreeing about
    /// what counts as local.
    public static func isLoopback(_ url: URL) -> Bool { Allowly.isLoopback(url) }
    public static let defaultModel = "jev-latest"

    public enum Question: Sendable {
        /// Single label chosen from a closed set.
        case choice(instructions: String, labels: [String])
        /// Calibrated yes/no probability.
        case noul(instructions: String)
        /// A choice whose options carry description rather than only a name.
        ///
        /// `choice` sends each label against null, which is right when the
        /// label says everything — an app name, a direction. It is not enough
        /// for picking one element out of a page, where the option is "[7]
        /// Search" and what distinguishes it from "[12] Search" is its role,
        /// its current value and whether it is already checked. Sendable
        /// values only: strings, numbers, bools, and arrays or dictionaries
        /// of those.
        case describedChoice(instructions: String, options: [String: [String: String]])

        /// The labels a choice was offered over, so a reply can be checked
        /// against exactly what was sent rather than what was hoped for.
        public var offeredLabels: Set<String>? {
            switch self {
            case .choice(_, let labels): return Set(labels)
            case .describedChoice(_, let options): return Set(options.keys)
            case .noul: return nil
            }
        }

        var json: [String: Any] {
            switch self {
            case .choice(let instructions, let labels):
                var criteria: [String: Any] = [:]
                for label in labels { criteria[label] = NSNull() }
                return ["type": "choice", "instructions": instructions, "criteria": criteria]
            case .noul(let instructions):
                return ["type": "noul", "instructions": instructions]
            case .describedChoice(let instructions, let options):
                return ["type": "choice", "instructions": instructions, "criteria": options]
            }
        }
    }

    public struct ChoiceAnswer: Sendable {
        public let choice: String
        public let confidence: Double
        public let probabilities: [String: Double]

        public init(choice: String, confidence: Double, probabilities: [String: Double]) {
            self.choice = choice
            self.confidence = confidence
            self.probabilities = probabilities
        }

        /// Whether this reply is a real choice over the options that were sent.
        ///
        /// Six checks, each with a way of being wrong that does not look
        /// wrong: a choice outside the offered set, a distribution over
        /// different keys than were offered, probabilities that do not sum to
        /// one, a value outside 0…1, a non-finite number, or an argmax that
        /// disagrees with the stated choice. Any of them means the answer did
        /// not describe a choice over the list we sent, and acting on it
        /// would be acting on nothing.
        ///
        /// Lived in the browser loop first; the sentence resolver — the code
        /// that decides whether to open a URL or turn a signed-in shop loose
        /// to an agent — applied none of it.
        public func isSound(offered: Set<String>) -> Bool {
            guard offered.contains(choice) else { return false }
            guard Set(probabilities.keys) == offered else { return false }
            let numbers = Array(probabilities.values) + [confidence]
            guard numbers.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else { return false }
            guard abs(probabilities.values.reduce(0, +) - 1) < 0.02 else { return false }
            guard let highest = probabilities.values.max(),
                  let chosen = probabilities[choice],
                  chosen >= highest - 1e-6 else { return false }
            return true
        }

        /// How decisively the choice beat the next best: 1.0 is a tie.
        ///
        /// Measured against the runner-up rather than a flat probability,
        /// because a flat floor breaks at both ends. One element out of
        /// sixty at p=0.3 is a strong answer that a 0.6 floor rejects; and
        /// "click free shipping to philippines" was refused at
        /// operation=0.57 while the same reply carried the right control at
        /// 0.78 — a floor on one scalar threw away the distribution it was
        /// cut from. Nil when there is nothing to compare against.
        public var runnerUpMargin: Double? {
            guard probabilities.count > 1, let chosen = probabilities[choice] else { return nil }
            let runnerUp = probabilities.filter { $0.key != choice }.values.max() ?? 0
            guard runnerUp > 0 else { return chosen > 0 ? 1000 : nil }
            return chosen / runnerUp
        }

        /// Twice the runner-up: a low bar that still refuses a toss-up, and
        /// one that means the same thing over two options or two hundred.
        public static let decisiveMargin = 2.0
        public var isDecisive: Bool { (runnerUpMargin ?? 0) >= Self.decisiveMargin }
    }

    public struct Answers: Sendable {
        public let choices: [String: ChoiceAnswer]
        public let nouls: [String: Double]

        public init(choices: [String: ChoiceAnswer], nouls: [String: Double]) {
            self.choices = choices
            self.nouls = nouls
        }

        public func choice(_ name: String) -> ChoiceAnswer? { choices[name] }

        /// The answer to a question, only if it is a sound choice over what
        /// that question offered. An unsound reply reads as no answer at all —
        /// which is what it is.
        public func soundChoice(_ name: String, offered: Set<String>?) -> ChoiceAnswer? {
            guard let answer = choices[name], let offered, answer.isSound(offered: offered) else { return nil }
            return answer
        }
        public func noul(_ name: String) -> Double? { nouls[name] }
    }

    public enum Failure: Error, CustomStringConvertible {
        case noKey
        case transport(String)
        case status(Int, String)
        case malformed(String)

        public var description: String {
            switch self {
            case .noKey: return "no TypeSafe API key"
            case .transport(let m): return "network: \(m)"
            case .status(let code, let body): return "HTTP \(code): \(body.prefix(200))"
            case .malformed(let m): return "unexpected response: \(m)"
            }
        }
    }

    public static func ask(
        state: [String: Any],
        questions: [String: Question],
        apiKey: String,
        model: String = defaultModel,
        timeout: TimeInterval = 8
    ) async -> Result<Answers, Failure> {
        guard !apiKey.isEmpty else { return .failure(.noKey) }

        var questionJSON: [String: Any] = [:]
        for (name, question) in questions { questionJSON[name] = question.json }
        let body: [String: Any] = ["state": state, "model": model, "questions": questionJSON]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            return .failure(.malformed("could not encode request"))
        }
        request.httpBody = payload

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                return .failure(.status(code, String(data: data, encoding: .utf8) ?? ""))
            }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = root["answers"] as? [String: Any] else {
                return .failure(.malformed("no answers object"))
            }

            var choices: [String: ChoiceAnswer] = [:]
            var nouls: [String: Double] = [:]
            for (name, value) in raw {
                guard let entry = value as? [String: Any] else { continue }
                if let choice = entry["choice"] as? String {
                    choices[name] = ChoiceAnswer(
                        choice: choice,
                        confidence: entry["confidence"] as? Double ?? 0,
                        probabilities: entry["probabilities"] as? [String: Double] ?? [:]
                    )
                } else if let noul = entry["noul"] as? Double {
                    nouls[name] = noul
                }
            }
            return .success(Answers(choices: choices, nouls: nouls))
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }

    /// The key, from the environment or the file the menu bar app writes.
    /// `open` does not inherit a shell environment, so the file is the path
    /// that actually works when Jev.app is launched normally.
    public static func loadAPIKey() -> String? {
        if let fromEnv = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"],
           !fromEnv.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fromEnv.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let url = Allowly.supportDirectory.appendingPathComponent("typesafe-api-key")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
