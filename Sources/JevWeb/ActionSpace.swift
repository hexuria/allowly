import Foundation

/// One executable thing the page offers.
///
/// Decoded from the vendored table builder rather than constructed here. The
/// fields that matter for safety are `node` — a code-owned identity, not a
/// selector and not anything a model produced — and `kind`, which decides
/// which operation may target it.
public struct WebAction: Sendable {
    /// Stable within one document, assigned by snapshot.js's WeakMap.
    public let node: Int
    /// `click`, `fill`, `select`, and the synthetic `scroll` and `wait`.
    public let kind: String
    public let role: String
    public let label: String
    public let value: String
    /// Only for `select`: the option value to choose.
    public let optionValue: String?
    public let currentValue: String?
    public let checked: String?
    public let selected: String?
    public let expanded: String?
    /// `e1`, `e2`, … or `scroll_down` / `scroll_up` / `wait`.
    public let id: String
    /// How far a scroll action moves, as the page reported it.
    public let scrollDelta: Int

    public var isSynthetic: Bool { node == Self.syntheticNode }
    static let syntheticNode = -1

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, let kind = json["kind"] as? String else { return nil }
        self.id = id
        self.kind = kind
        self.node = (json["node"] as? Int) ?? Self.syntheticNode
        self.role = (json["role"] as? String) ?? kind
        self.label = (json["label"] as? String) ?? ""
        self.value = (json["value"] as? String) ?? ""
        self.optionValue = kind == "select" ? json["value"] as? String : nil
        self.currentValue = json["current_value"] as? String
        self.checked = json["checked"] as? String
        self.selected = json["selected"] as? String
        self.expanded = json["expanded"] as? String
        self.scrollDelta = (json["delta"] as? Int) ?? 560
    }
}

/// The page as a set of choices.
///
/// This is the port of the reference implementation's `action_space`, and its
/// shape is the safety property worth keeping: **one node gets one index**,
/// even when it can be both clicked and typed into, and each operation is
/// offered its own list of targets. A model that picks TYPE_TEXT cannot then
/// name a target that is only clickable, because that target was never in the
/// list it was choosing from.
public struct ActionSpace: Sendable {

    /// What the model is shown about each element: an index and enough state
    /// to tell two same-named controls apart.
    public struct Element: Sendable {
        public let index: String
        public let label: String
        public let role: String
        public let value: String
        public var operations: [String]
        public var options: [(index: String, label: String, value: String)]
    }

    public let elements: [Element]
    /// operation -> target index -> the action to run.
    public let targets: [String: [String: WebAction]]
    /// The page-level controls, keyed by the name the model sees.
    public let controls: [String: WebAction]

    static let operationForKind = ["click": "CLICK", "fill": "TYPE_TEXT", "select": "SELECT"]
    static let pageLevelKinds: Set<String> = ["scroll", "wait"]

    public init(actions: [WebAction]) {
        var elements: [Element] = []
        var indexForNode: [Int: String] = [:]
        var targets: [String: [String: WebAction]] = [:]
        var controls: [String: WebAction] = [:]

        for action in actions {
            guard let operation = Self.operationForKind[action.kind] else {
                // Page-level controls, named explicitly. Anything else is a
                // kind this code does not know how to carry out — and the
                // table builder is vendored, so a future version could
                // introduce one. Offering an unknown kind as a control would
                // hand it to the model with no target check and then fall
                // through to the click path, so it is dropped instead.
                if Self.pageLevelKinds.contains(action.kind) {
                    controls[action.id.uppercased()] = action
                }
                continue
            }

            let index: String
            if let existing = indexForNode[action.node] {
                index = existing
            } else {
                index = String(elements.count + 1)
                indexForNode[action.node] = index
                // A select shows what is chosen now, not the option being
                // offered — the option is the target, the current value is
                // what distinguishes this dropdown from the next one.
                let shown = action.kind == "select" ? (action.currentValue ?? "") : action.value
                elements.append(Element(
                    index: index,
                    // "Country → Japan" is an option label; the element is
                    // "Country".
                    label: action.label.components(separatedBy: " → ").first ?? action.label,
                    role: action.role,
                    value: shown,
                    operations: [],
                    options: []))
            }

            guard let position = elements.firstIndex(where: { $0.index == index }) else { continue }
            if !elements[position].operations.contains(operation) {
                elements[position].operations.append(operation)
            }

            var target = index
            if action.kind == "select" {
                // The option index is code-owned too: the model picks "3:2",
                // and which option that is was decided here.
                target = "\(index):\(elements[position].options.count + 1)"
                elements[position].options.append(
                    (index: target, label: action.label, value: action.optionValue ?? ""))
            }
            targets[operation, default: [:]][target] = action
        }

        self.elements = elements
        self.targets = targets
        self.controls = controls
    }

    /// Whether an index the model returned names something real.
    ///
    /// The only way an action ever gets run: look it up, or refuse.
    public func action(operation: String, target: String) -> WebAction? {
        targets[operation]?[target]
    }
}
