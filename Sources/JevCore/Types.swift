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

    /// Did the thing asked for actually happen?
    ///
    /// Separate from `status` because "the instruction was delivered"
    /// and "the Mac acted on it" are different facts, and a macOS
    /// consent sheet is the case where they come apart: it accepts a
    /// synthetic press, reports success, and does nothing.
    ///
    /// `true` for everything that has no way to tell — this is a
    /// downgrade from a claim, not an upgrade to one, and only the
    /// paths that genuinely check ever set it false. Three places in
    /// `Runtime` decide whether to take a card off the phone; all three
    /// read this, because a dialog that is still on screen must keep
    /// its card or it can never be answered at all.
    public let landed: Bool

    public init(status: ExecutionStatus, reason: String, landed: Bool = true) {
        self.status = status
        self.reason = reason
        self.landed = landed
    }

    /// Absent means `true`.
    ///
    /// Nothing in the tree decodes an `ExecutionResult` today — it is
    /// encoded on the Mac and read as plain JSON by the phone — so this
    /// is insurance, not a fix for a known caller. Said plainly because
    /// the first version of this comment claimed to protect "an older
    /// client's payload", which described a direction that does not
    /// exist.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(ExecutionStatus.self, forKey: .status)
        reason = try container.decode(String.self, forKey: .reason)
        landed = try container.decodeIfPresent(Bool.self, forKey: .landed) ?? true
    }

    public static func ok(reason: String = "Success", landed: Bool = true) -> ExecutionResult {
        ExecutionResult(status: .ok, reason: reason, landed: landed)
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
    /// Click a control by name, optionally the nth of several that share
    /// that name.
    ///
    /// `nth` is 1-based and counts only the equally-good candidates, in
    /// the order the screen reports them (reading order). It exists so an
    /// answer to "which of these three?" can travel the ordinary route —
    /// through the policy check, the approval card, the risk rating and
    /// the journal — instead of being laundered into a raw
    /// `clickPoint`, which carries no label and therefore no rating.
    case clickControl(label: String, nth: Int? = nil, outOf: Int? = nil,
                      inWindow: Int? = nil)
    case typeText(text: String)
    case clickPoint(x: Double, y: Double)
    case scroll(direction: String, amount: Int)
    case switchWorkspace(id: String)
    case pressKeys(spec: String)
    case rightClickControl(label: String, nth: Int? = nil, outOf: Int? = nil,
                           inWindow: Int? = nil)
    /// Put text into a named field, found by its accessibility label.
    case fillField(label: String, text: String)
    /// Open a URL in the default browser. Vastly more reliable than typing one.
    case openURL(url: String)
    /// Volume, brightness, appearance — things keystrokes do not reach well.
    case systemAction(name: String, value: Int)
    /// Act wherever the pointer already is. "this" and "here" are the fastest
    /// way to say what you mean when you can see the pointer on your phone and
    /// put it where you want it.
    case pointerAction(kind: String)
    /// Ask the phone for text rather than taking it from speech. A password
    /// must never go through a microphone or a transcription service.
    case requestInput(field: String, secret: Bool)
    /// Read the form in front of you and show it on the phone to be filled in.
    case showForm
    /// Number everything pressable and show the numbers on the phone, for
    /// when two controls share a name and saying it cannot choose between
    /// them — four buttons all called "Alex" in Chrome's profile picker.
    case showNumbers(on: Bool)
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
        case on
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
            // `nth` rides in the same field, after the label, because the
            // wire format has a fixed set of keys. Absent means "the only
            // one", which is what every older payload means.
            let raw = try container.decode(String.self, forKey: .optionId)
            let parts = raw.components(separatedBy: "\u{001F}")
            if parts.count >= 3, let ordinal = Int(parts[1]), let total = Int(parts[2]) {
                self = .clickControl(label: parts[0], nth: ordinal, outOf: total,
                                     inWindow: parts.count > 3 ? Int(parts[3]) : nil)
            } else {
                self = .clickControl(label: raw, nth: nil, outOf: nil)
            }
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
            let rawRight = try container.decode(String.self, forKey: .optionId)
            let rightParts = rawRight.components(separatedBy: "\u{001F}")
            if rightParts.count >= 3, let n = Int(rightParts[1]), let t = Int(rightParts[2]) {
                self = .rightClickControl(label: rightParts[0], nth: n, outOf: t,
                                          inWindow: rightParts.count > 3 ? Int(rightParts[3]) : nil)
            } else {
                self = .rightClickControl(label: rawRight, nth: nil, outOf: nil)
            }
        case "systemAction":
            self = .systemAction(name: try container.decode(String.self, forKey: .optionId),
                                 value: Int(try container.decode(String.self, forKey: .fullCommand)) ?? 0)
        case "pointerAction":
            self = .pointerAction(kind: try container.decode(String.self, forKey: .optionId))
        case "showNumbers":
            self = .showNumbers(on: (try? container.decode(Bool.self, forKey: .on)) ?? true)
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
        case .clickControl(let label, let nth, let outOf, let inWindow):
            try container.encode("clickControl", forKey: .type)
            // A unit separator, which cannot occur in an accessibility
            // label, so a label containing any ordinary punctuation
            // round-trips unharmed. All three parts or none, so a label
            // that somehow DOES contain one cannot be silently split:
            // it simply decodes back as itself.
            if let nth, let outOf {
                let window = inWindow.map { "\u{001F}\($0)" } ?? ""
                try container.encode("\(label)\u{001F}\(nth)\u{001F}\(outOf)\(window)",
                                     forKey: .optionId)
            } else {
                try container.encode(label, forKey: .optionId)
            }
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
        case .rightClickControl(let label, let nth, let outOf, let inWindow):
            try container.encode("rightClickControl", forKey: .type)
            if let nth, let outOf {
                let window = inWindow.map { "\u{001F}\($0)" } ?? ""
                try container.encode("\(label)\u{001F}\(nth)\u{001F}\(outOf)\(window)",
                                     forKey: .optionId)
            } else {
                try container.encode(label, forKey: .optionId)
            }
        case .systemAction(let name, let value):
            try container.encode("systemAction", forKey: .type)
            try container.encode(name, forKey: .optionId)
            try container.encode(String(value), forKey: .fullCommand)
        case .pointerAction(let kind):
            try container.encode("pointerAction", forKey: .type)
            try container.encode(kind, forKey: .optionId)
        case .showForm:
            try container.encode("showForm", forKey: .type)
        case .showNumbers(let on):
            try container.encode("showNumbers", forKey: .type)
            try container.encode(on, forKey: .on)
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
        case .pointerAction: return "system.pointer"
        case .requestInput, .showForm: return "system.keyboard"
        // Numbering only draws on the phone; it touches nothing on the Mac.
        case .showNumbers: return nil
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
