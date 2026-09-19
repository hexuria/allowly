import Foundation

// MARK: - Enums

public enum ApprovalKind: String, Codable, Sendable {
    case agentToolPrompt
    case appDialog
    case tccConsent
    case spokenCommand
}

public enum RiskLevel: String, Codable, Sendable, Comparable {
    case low
    case medium
    case high

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        let order: [RiskLevel] = [.low, .medium, .high]
        return order.firstIndex(of: lhs) ?? -1 < order.firstIndex(of: rhs) ?? -1
    }
}

public enum DecisionValue: String, Codable, Sendable {
    case allow
    case deny
    case askHuman
}

public enum DecisionSource: String, Codable, Sendable {
    case policy
    case jev
    case human
}

public enum ExecutionStatus: String, Codable, Sendable {
    case ok
    case failed
}

// MARK: - Value Types

public struct ApprovalOption: Codable, Sendable, Equatable {
    public let id: String
    public let label: String
    public let riskLevel: RiskLevel

    public init(id: String, label: String, riskLevel: RiskLevel) {
        self.id = id
        self.label = label
        self.riskLevel = riskLevel
    }
}

public struct ApplicationInfo: Codable, Sendable, Equatable {
    public let name: String
    public let bundleIdentifier: String

    public init(name: String, bundleIdentifier: String) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
    }
}

public struct ApprovalRequest: Codable, Sendable, Identifiable {
    public let id: String
    public let kind: ApprovalKind
    public let title: String
    public let bodyText: String
    public let options: [ApprovalOption]
    public let originatingApp: ApplicationInfo
    public let timestamp: Date
    public let screenshotReference: String?
    public let handoffOnly: Bool

    public init(
        id: String,
        kind: ApprovalKind,
        title: String,
        bodyText: String,
        options: [ApprovalOption],
        originatingApp: ApplicationInfo,
        timestamp: Date,
        screenshotReference: String? = nil,
        handoffOnly: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.bodyText = bodyText
        self.options = options
        self.originatingApp = originatingApp
        self.timestamp = timestamp
        self.screenshotReference = screenshotReference
        self.handoffOnly = handoffOnly
    }
}

public struct Decision: Codable, Sendable {
    public let value: DecisionValue
    public let chosenOptionId: String?
    public let confidence: Double
    public let reason: String
    public let source: DecisionSource

    public init(
        value: DecisionValue,
        chosenOptionId: String? = nil,
        confidence: Double,
        reason: String,
        source: DecisionSource
    ) {
        self.value = value
        self.chosenOptionId = chosenOptionId
        self.confidence = confidence
        self.reason = reason
        self.source = source
    }
}

public struct ExecutionResult: Codable, Sendable {
    public let status: ExecutionStatus
    public let reason: String

    public init(status: ExecutionStatus, reason: String) {
        self.status = status
        self.reason = reason
    }

    public static func ok(reason: String = "Success") -> ExecutionResult {
        ExecutionResult(status: .ok, reason: reason)
    }

    public static func failed(reason: String) -> ExecutionResult {
        ExecutionResult(status: .failed, reason: reason)
    }
}

public enum Command: Codable, Sendable {
    case launchApp(bundleIdentifier: String)
    case quitApp(bundleIdentifier: String)
    /// Show it if hidden or in the background, hide it if it is in front.
    case toggleApp(bundleIdentifier: String)
    case showApp(bundleIdentifier: String)
    case hideApp(bundleIdentifier: String)
    case clickControl(label: String)
    case typeText(text: String)
    case clickPoint(x: Double, y: Double)
    case scroll(direction: String, amount: Int)
    case switchWorkspace(id: String)
    case pressKeys(spec: String)
    case rightClickControl(label: String)
    /// Put text into a named field, found by its accessibility label.
    case fillField(label: String, text: String)
    /// Open a URL in the default browser. Vastly more reliable than typing one.
    case openURL(url: String)
    /// Number every actionable thing on screen and show it on the phone.
    case showHints
    case showHintsForApp(bundleIdentifier: String)
    case showHintsEverywhere
    /// Narrow the numbers to a kind of thing and/or a part of the window.
    case showHintsScoped(kind: String, region: String)
    /// Outline a single number without covering the screen in boxes.
    case showHintBox(number: Int)
    /// Volume, brightness, appearance — things keystrokes do not reach well.
    case systemAction(name: String, value: Int)
    /// Act on one of those numbers.
    case selectHint(number: Int)
    /// Take the numbers down again.
    case hideHints
    /// Act wherever the pointer already is. "this" and "here" are the fastest
    /// way to say what you mean when you can see the pointer on your phone and
    /// put it where you want it.
    case pointerAction(kind: String)
    /// Ask the phone for text rather than taking it from speech. A password
    /// must never go through a microphone or a transcription service.
    case requestInput(field: String, secret: Bool)
    /// Read the form in front of you and show it on the phone to be filled in.
    case showForm
    /// Several steps run in order, with a short pause between them.
    /// "Go to a URL" is not one action: it is new tab, focus the bar, select
    /// what is there, type, Enter.
    indirect case sequence(label: String, steps: [Command])
    case pressButton(requestId: String, optionId: String)
    case runCommand(allowlistedPrefix: String, fullCommand: String)
    case answerAgentPrompt(requestId: String, optionId: String)

    enum CodingKeys: String, CodingKey {
        case type
        case bundleIdentifier
        case requestId
        case optionId
        case allowlistedPrefix
        case fullCommand
        case steps
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "launchApp":
            let bundleId = try container.decode(String.self, forKey: .bundleIdentifier)
            self = .launchApp(bundleIdentifier: bundleId)
        case "quitApp":
            let bundleId = try container.decode(String.self, forKey: .bundleIdentifier)
            self = .quitApp(bundleIdentifier: bundleId)
        case "toggleApp":
            self = .toggleApp(bundleIdentifier: try container.decode(String.self, forKey: .bundleIdentifier))
        case "showApp":
            self = .showApp(bundleIdentifier: try container.decode(String.self, forKey: .bundleIdentifier))
        case "hideApp":
            self = .hideApp(bundleIdentifier: try container.decode(String.self, forKey: .bundleIdentifier))
        case "clickControl":
            self = .clickControl(label: try container.decode(String.self, forKey: .optionId))
        case "typeText":
            self = .typeText(text: try container.decode(String.self, forKey: .fullCommand))
        case "clickPoint":
            let parts = try container.decode(String.self, forKey: .fullCommand).split(separator: ",")
            self = .clickPoint(x: Double(parts.first ?? "0") ?? 0, y: Double(parts.last ?? "0") ?? 0)
        case "scroll":
            let parts = try container.decode(String.self, forKey: .fullCommand).split(separator: ",")
            self = .scroll(direction: String(parts.first ?? "down"), amount: Int(parts.last ?? "5") ?? 5)
        case "switchWorkspace":
            self = .switchWorkspace(id: try container.decode(String.self, forKey: .optionId))
        case "pressKeys":
            self = .pressKeys(spec: try container.decode(String.self, forKey: .optionId))
        case "rightClickControl":
            self = .rightClickControl(label: try container.decode(String.self, forKey: .optionId))
        case "showHints":
            self = .showHints
        case "showHintsForApp":
            self = .showHintsForApp(bundleIdentifier: try container.decode(String.self, forKey: .bundleIdentifier))
        case "showHintsEverywhere":
            self = .showHintsEverywhere
        case "showHintsScoped":
            self = .showHintsScoped(kind: try container.decode(String.self, forKey: .optionId),
                                    region: try container.decode(String.self, forKey: .fullCommand))
        case "systemAction":
            self = .systemAction(name: try container.decode(String.self, forKey: .optionId),
                                 value: Int(try container.decode(String.self, forKey: .fullCommand)) ?? 0)
        case "showHintBox":
            self = .showHintBox(number: Int(try container.decode(String.self, forKey: .optionId)) ?? 0)
        case "selectHint":
            self = .selectHint(number: Int(try container.decode(String.self, forKey: .optionId)) ?? 0)
        case "hideHints":
            self = .hideHints
        case "pointerAction":
            self = .pointerAction(kind: try container.decode(String.self, forKey: .optionId))
        case "showForm":
            self = .showForm
        case "requestInput":
            self = .requestInput(field: try container.decode(String.self, forKey: .optionId),
                                 secret: try container.decode(String.self, forKey: .fullCommand) == "true")
        case "openURL":
            self = .openURL(url: try container.decode(String.self, forKey: .fullCommand))
        case "fillField":
            self = .fillField(label: try container.decode(String.self, forKey: .optionId),
                              text: try container.decode(String.self, forKey: .fullCommand))
        case "sequence":
            self = .sequence(
                label: try container.decode(String.self, forKey: .optionId),
                steps: try container.decode([Command].self, forKey: .steps))
        case "pressButton":
            let reqId = try container.decode(String.self, forKey: .requestId)
            let optId = try container.decode(String.self, forKey: .optionId)
            self = .pressButton(requestId: reqId, optionId: optId)
        case "runCommand":
            let prefix = try container.decode(String.self, forKey: .allowlistedPrefix)
            let fullCmd = try container.decode(String.self, forKey: .fullCommand)
            self = .runCommand(allowlistedPrefix: prefix, fullCommand: fullCmd)
        case "answerAgentPrompt":
            let reqId = try container.decode(String.self, forKey: .requestId)
            let optId = try container.decode(String.self, forKey: .optionId)
            self = .answerAgentPrompt(requestId: reqId, optionId: optId)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown command type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .launchApp(let bundleId):
            try container.encode("launchApp", forKey: .type)
            try container.encode(bundleId, forKey: .bundleIdentifier)
        case .quitApp(let bundleId):
            try container.encode("quitApp", forKey: .type)
            try container.encode(bundleId, forKey: .bundleIdentifier)
        case .toggleApp(let bundleId):
            try container.encode("toggleApp", forKey: .type)
            try container.encode(bundleId, forKey: .bundleIdentifier)
        case .showApp(let bundleId):
            try container.encode("showApp", forKey: .type)
            try container.encode(bundleId, forKey: .bundleIdentifier)
        case .hideApp(let bundleId):
            try container.encode("hideApp", forKey: .type)
            try container.encode(bundleId, forKey: .bundleIdentifier)
        case .clickControl(let label):
            try container.encode("clickControl", forKey: .type)
            try container.encode(label, forKey: .optionId)
        case .typeText(let text):
            try container.encode("typeText", forKey: .type)
            try container.encode(text, forKey: .fullCommand)
        case .clickPoint(let x, let y):
            try container.encode("clickPoint", forKey: .type)
            try container.encode("\(x),\(y)", forKey: .fullCommand)
        case .scroll(let direction, let amount):
            try container.encode("scroll", forKey: .type)
            try container.encode("\(direction),\(amount)", forKey: .fullCommand)
        case .switchWorkspace(let id):
            try container.encode("switchWorkspace", forKey: .type)
            try container.encode(id, forKey: .optionId)
        case .pressKeys(let spec):
            try container.encode("pressKeys", forKey: .type)
            try container.encode(spec, forKey: .optionId)
        case .rightClickControl(let label):
            try container.encode("rightClickControl", forKey: .type)
            try container.encode(label, forKey: .optionId)
        case .showHints:
            try container.encode("showHints", forKey: .type)
        case .showHintsForApp(let bundleId):
            try container.encode("showHintsForApp", forKey: .type)
            try container.encode(bundleId, forKey: .bundleIdentifier)
        case .showHintsEverywhere:
            try container.encode("showHintsEverywhere", forKey: .type)
        case .showHintsScoped(let kind, let region):
            try container.encode("showHintsScoped", forKey: .type)
            try container.encode(kind, forKey: .optionId)
            try container.encode(region, forKey: .fullCommand)
        case .systemAction(let name, let value):
            try container.encode("systemAction", forKey: .type)
            try container.encode(name, forKey: .optionId)
            try container.encode(String(value), forKey: .fullCommand)
        case .showHintBox(let number):
            try container.encode("showHintBox", forKey: .type)
            try container.encode(String(number), forKey: .optionId)
        case .selectHint(let number):
            try container.encode("selectHint", forKey: .type)
            try container.encode(String(number), forKey: .optionId)
        case .hideHints:
            try container.encode("hideHints", forKey: .type)
        case .pointerAction(let kind):
            try container.encode("pointerAction", forKey: .type)
            try container.encode(kind, forKey: .optionId)
        case .showForm:
            try container.encode("showForm", forKey: .type)
        case .requestInput(let field, let secret):
            try container.encode("requestInput", forKey: .type)
            try container.encode(field, forKey: .optionId)
            try container.encode(secret ? "true" : "false", forKey: .fullCommand)
        case .openURL(let url):
            try container.encode("openURL", forKey: .type)
            try container.encode(url, forKey: .fullCommand)
        case .fillField(let label, let text):
            try container.encode("fillField", forKey: .type)
            try container.encode(label, forKey: .optionId)
            try container.encode(text, forKey: .fullCommand)
        case .sequence(let label, let steps):
            try container.encode("sequence", forKey: .type)
            try container.encode(label, forKey: .optionId)
            try container.encode(steps, forKey: .steps)
        case .pressButton(let reqId, let optId):
            try container.encode("pressButton", forKey: .type)
            try container.encode(reqId, forKey: .requestId)
            try container.encode(optId, forKey: .optionId)
        case .runCommand(let prefix, let fullCmd):
            try container.encode("runCommand", forKey: .type)
            try container.encode(prefix, forKey: .allowlistedPrefix)
            try container.encode(fullCmd, forKey: .fullCommand)
        case .answerAgentPrompt(let reqId, let optId):
            try container.encode("answerAgentPrompt", forKey: .type)
            try container.encode(reqId, forKey: .requestId)
            try container.encode(optId, forKey: .optionId)
        }
    }
}

public extension Command {
    /// The app a command acts on, when it acts on one.
    var bundleIdentifier: String? {
        switch self {
        case .launchApp(let id), .quitApp(let id), .toggleApp(let id),
             .showApp(let id), .hideApp(let id): return id
        case .scroll: return "system.gesture"
        case .switchWorkspace: return "system.workspace"
        case .clickControl, .clickPoint, .rightClickControl: return "system.pointer"
        case .sequence(_, let steps): return steps.first?.bundleIdentifier ?? "system.keyboard"
        case .typeText, .pressKeys, .fillField: return "system.keyboard"
        case .openURL: return "system.browser"
        case .systemAction: return "system.settings"
        case .showHints, .showHintsForApp, .showHintsEverywhere,
             .showHintsScoped, .showHintBox, .hideHints: return "system.hints"
        case .selectHint, .pointerAction: return "system.pointer"
        case .requestInput, .showForm: return "system.keyboard"
        case .pressButton, .runCommand, .answerAgentPrompt: return nil
        }
    }
}

public struct Nonce: Codable, Sendable, Equatable {
    public let id: String
    public let timestamp: Date

    private static let replayWindowSeconds: TimeInterval = 30

    public init(id: String, timestamp: Date) {
        self.id = id
        self.timestamp = timestamp
    }

    /// Accept either an object {id, timestamp} or the bare string the browser
    /// actually sends — "<epoch-ms>-<random>". The mismatch made every decision
    /// POST fail to decode, surfacing on the phone as a generic
    /// "Failed to submit decision" with no clue that the shape was wrong.
    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let text = try? single.decode(String.self) {
            self.id = text
            let millis = text.split(separator: "-").first.flatMap { Double($0) }
            self.timestamp = millis.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        if let seconds = try? container.decode(Double.self, forKey: .timestamp) {
            self.timestamp = Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1000 : seconds)
        } else {
            let text = try container.decode(String.self, forKey: .timestamp)
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            guard let date = withFraction.date(from: text) ?? plain.date(from: text) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .timestamp, in: container,
                    debugDescription: "Unrecognised timestamp: \(text)")
            }
            self.timestamp = date
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case timestamp
    }

    public func isValid(against previous: Nonce?) -> Bool {
        // Freshness is unconditional. Checking it only when a previous nonce
        // exists would mean the first request of a session — or any request
        // after a restart — could be one captured and replayed hours later.
        let age = Date().timeIntervalSince(self.timestamp)
        guard age <= Self.replayWindowSeconds else { return false }

        // A timestamp meaningfully in the future is a skewed or forged clock;
        // either way it would stretch the window arbitrarily.
        guard age >= -Self.replayWindowSeconds else { return false }

        // Then reject anything already seen.
        if let previous, self.id == previous.id { return false }

        return true
    }
}

public struct DeviceIdentity: Codable, Sendable, Equatable {
    public let id: String
    public let label: String
    public let pushSubscription: String
    public let pairedAt: Date

    public init(id: String, label: String, pushSubscription: String, pairedAt: Date) {
        self.id = id
        self.label = label
        self.pushSubscription = pushSubscription
        self.pairedAt = pairedAt
    }
}
