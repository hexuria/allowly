import Foundation

/// Read the page, decide one step, do it, read again.
///
/// The loop is deliberately small, and everything interesting about it is a
/// bound or a refusal:
///
/// - Every step is chosen from a table this code built. The model returns an
///   index; what that index means was decided here.
/// - Nothing runs if the page changed between deciding and acting.
/// - Nothing runs after the budget, which exists because "kept trying" is a
///   failure mode of its own on a page that never settles.
/// - The tab is left open whatever happens, so there is something to look at.
public actor WebAgent {

    /// The reference implementation's bounds, kept. Sixty actions is far more
    /// than any sane task and far less than a loop.
    public static let maximumActions = 60
    public static let maximumDecisions = 120
    public static let maximumSeconds: TimeInterval = 90
    /// Attempts at one chosen action before going back to the model. Small:
    /// a page that will not hold still for three tries is telling us the
    /// decision needs remaking, not repeating.
    public static let retriesPerStep = 3
    /// Unusable answers — malformed, or the model call failing — tolerated
    /// across a whole run before giving up. Nothing is ever executed from one;
    /// this only decides how long to keep asking.
    public static let badAnswersAllowed = 3
    /// How far ahead of the runner-up a target must be before jev acts on it.
    /// Twice is a low bar that still refuses a genuine toss-up, and it means
    /// the same thing whether the page offered two candidates or two hundred.
    public static let targetStrengthFloor = 2.0

    public enum Outcome: Sendable {
        case done(steps: Int, url: String, title: String)
        /// The model refused, or the rules did.
        case blocked(reason: String, steps: Int, url: String, title: String)
        /// Allowed, but no way forward was found. Not a refusal, and it must
        /// not be reported as one.
        case stuck(steps: Int, url: String, title: String)
        case exhausted(steps: Int, url: String, title: String)
        case failed(reason: String, steps: Int)
    }

    /// What the phone is told while this runs.
    public struct Progress: Sendable {
        public let step: Int
        public let operation: String
        public let target: String
        public let url: String
        public let title: String
        /// True when this is another attempt at the same step rather than a
        /// new one. Without it a retry is indistinguishable from progress in
        /// the log, which is how thirteen lines came to describe three steps.
        public let isRetry: Bool
    }

    private let session: WebSession
    private let apiKey: String
    private let onProgress: @Sendable (Progress) -> Void

    public init(session: WebSession, apiKey: String,
                onProgress: @escaping @Sendable (Progress) -> Void = { _ in }) {
        self.session = session
        self.apiKey = apiKey
        self.onProgress = onProgress
    }

    public func run(goal: String) async -> Outcome {
        let deadline = Date().addingTimeInterval(Self.maximumSeconds)
        var history: [String] = []
        var steps = 0
        var decisions = 0
        var badAnswers = 0
        var lastURL = ""
        var lastTitle = ""
        /// Nodes that would not be acted on, however many times they were
        /// chosen. Without this the loop is stable but useless: the model
        /// keeps picking the one sensible target, the executor keeps refusing
        /// it, and the budget drains on a decision that can never land.
        ///
        /// Cleared on every new document, because node ids restart at 1 in
        /// each one. Carried across, "node 3 was unreachable on the home page"
        /// silently deletes the first search result from the next page.
        var refusedNodes: Set<Int> = []
        var refusedIn: Double?

        while steps < Self.maximumActions, decisions < Self.maximumDecisions, Date() < deadline {
            let snapshot: WebSnapshot
            do {
                snapshot = try await session.observe()
            } catch WebSession.Failure.documentNavigating {
                // A redirect mid-read is ordinary. Let it land and look again.
                try? await Task.sleep(nanoseconds: 150_000_000)
                decisions += 1
                continue
            } catch {
                return .failed(reason: "could not read the page", steps: steps)
            }
            lastURL = snapshot.url
            lastTitle = snapshot.title

            if refusedIn != snapshot.documentToken {
                refusedNodes.removeAll()
                refusedIn = snapshot.documentToken
            }

            let space = ActionSpace(actions: snapshot.actions.filter {
                $0.isSynthetic || !refusedNodes.contains($0.node)
            })
            guard !space.elements.isEmpty || !space.controls.isEmpty else {
                return .stuck(steps: steps, url: lastURL, title: lastTitle)
            }

            decisions += 1
            let decided = await WebChoice.next(space: space, goal: goal, page: snapshot.page,
                                               history: history, apiKey: apiKey)
            guard case .success(let decision) = decided else {
                guard case .failure(let refusal) = decided else {
                    return .failed(reason: "no decision", steps: steps)
                }
                // Neither kind is a reason to end the task on the first
                // occurrence. An unsound answer means this reply did not
                // describe a choice over the list we sent, so nothing is run —
                // but the page moves, the question is asked afresh next round,
                // and the answer is usually fine. A transport failure says
                // nothing about the page at all. Both are bounded: the count
                // is shared, so a run that cannot get a usable answer still
                // stops quickly rather than burning the whole budget.
                badAnswers += 1
                guard badAnswers <= Self.badAnswersAllowed else {
                    return .failed(reason: Self.describe(refusal), steps: steps)
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
                continue
            }

            switch decision.operation {
            case "DONE":
                return .done(steps: steps, url: lastURL, title: lastTitle)
            case "BLOCKED":
                return .blocked(reason: "the next step is something jev will not do unasked",
                                steps: steps, url: lastURL, title: lastTitle)
            case "STUCK":
                return .stuck(steps: steps, url: lastURL, title: lastTitle)
            default:
                break
            }

            // Page-level control, or an element target. Either way the action
            // comes out of the table, never out of the answer.
            let action: WebAction?
            if let control = space.controls[decision.operation] {
                action = control
            } else if let target = decision.target {
                action = space.action(operation: decision.operation, target: target)
            } else {
                action = nil
            }
            guard let action else {
                return .failed(reason: "chose something that is not on the page", steps: steps)
            }

            // Soundness says the answer was a real choice over the list we
            // sent; it says nothing about conviction. Checked only here, once
            // the terminal answers are out of the way — a low-confidence DONE
            // still means the model believes the goal is met, and reporting
            // that as "could not find a way" was worse than reporting it.
            if let strength = decision.targetStrength, strength < Self.targetStrengthFloor {
                return .stuck(steps: steps, url: lastURL, title: lastTitle)
            }

            var typed: String?
            if action.kind == "fill" {
                let asked = await WebTextModel.text(
                    goal: goal, fieldLabel: action.label, fieldRole: action.role,
                    currentValue: action.currentValue ?? action.value, pageTitle: snapshot.title)
                guard case .success(let value) = asked else {
                    return .failed(reason: "could not work out what to type", steps: steps)
                }
                typed = value
            }

            onProgress(Progress(step: steps + 1, operation: decision.operation,
                                target: action.label, url: lastURL, title: lastTitle,
                                isRetry: false))

            // Re-attempt the SAME action rather than re-deciding.
            //
            // A guard failure usually means the page moved, not that the
            // choice was wrong; going back to the model costs a call and —
            // measured — often returns a different answer, so the agent
            // oscillates between two plausible targets instead of doing
            // either. But a retry must not become a way around the guard,
            // which is the one thing standing between "click what was chosen"
            // and "click whatever is there now". So a retry requires the same
            // document, the same node, and the same label, kind and role —
            // node identity alone proves nothing, because ids restart at 1 in
            // every document and are handed out in the same order, so index n
            // maps to node n on the first reading of any page.
            var attempt = 0
            var carriedOut = false
            var dispatched = false
            var current = snapshot
            var target = action

            while attempt < Self.retriesPerStep, !carriedOut {
                do {
                    dispatched = true
                    try await session.perform(target, from: current, text: typed)
                    carriedOut = true
                } catch WebSession.Failure.pageChanged, WebSession.Failure.targetMoved {
                    // Nothing was dispatched: both of these are thrown before
                    // any input event. Anything else might have landed.
                    dispatched = false
                    attempt += 1
                    guard attempt < Self.retriesPerStep,
                          let again = try? await session.observe(),
                          again.documentToken == current.documentToken
                    else { break }

                    // Filtered the same way as the space the decision was made
                    // from, or the indices mean different elements.
                    let reoffered = ActionSpace(actions: again.actions.filter {
                        $0.isSynthetic || !refusedNodes.contains($0.node)
                    })
                    guard let index = decision.target,
                          let same = reoffered.action(operation: decision.operation, target: index),
                          same.node == target.node, same.kind == target.kind,
                          same.role == target.role, same.label == target.label
                    else { break }

                    onProgress(Progress(step: steps + 1, operation: decision.operation,
                                        target: target.label, url: again.url,
                                        title: again.title, isRetry: true))
                    lastURL = again.url
                    lastTitle = again.title
                    current = again
                    target = same
                } catch {
                    // Could be anything, including a reply lost after the
                    // click was delivered. Never retried: a second
                    // "Add to cart" is worse than a task that stops.
                    return .failed(reason: dispatched
                        ? "a step may have gone through but could not be confirmed"
                        : "could not carry out that step", steps: steps)
                }
            }

            guard carriedOut else {
                // Tried and could not. Take it off the table so the next
                // decision is made without it, and say so in the history so
                // the model knows this was attempted rather than overlooked.
                if !target.isSynthetic { refusedNodes.insert(target.node) }
                history.append("\(decision.operation) \(action.label) — could not be acted on")
                continue
            }
            steps += 1
            // What was typed is deliberately not recorded: this goes into the
            // next model request, and a field value can be anything the goal
            // named.
            history.append("\(decision.operation) \(action.label)")

            // Let the page react. Long enough for a render, short enough that
            // a task does not feel padded.
            try? await Task.sleep(nanoseconds: 120_000_000)
        }

        return .exhausted(steps: steps, url: lastURL, title: lastTitle)
    }

    static func describe(_ refusal: WebChoice.Refusal) -> String {
        switch refusal {
        case .api(let detail): return "the decision model could not be reached (\(detail))"
        case .unsound(let which): return "the answer about \(which) did not hold together"
        case .noTargetForOperation(let operation): return "nothing on the page can be \(operation.lowercased())ed"
        }
    }
}
