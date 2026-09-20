import Foundation

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
    public static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
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
    }

    public struct Answers: Sendable {
        public let choices: [String: ChoiceAnswer]
        public let nouls: [String: Double]

        public func choice(_ name: String) -> ChoiceAnswer? { choices[name] }
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
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/jev/typesafe-api-key")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
