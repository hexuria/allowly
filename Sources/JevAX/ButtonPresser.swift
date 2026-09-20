import Foundation
import ApplicationServices
import AppKit
import JevCore

/// Result of attempting to press a button in a dialog.
public enum ButtonPressResult: Sendable {
    /// `dialogGone` is what happened AFTER the press, not what the press
    /// returned. A macOS consent sheet accepts `AXPress`, answers
    /// `.success`, and does nothing — so "the API said yes" and "the
    /// thing you asked for happened" are different questions, and only
    /// the second one is worth reporting to someone who is not in the
    /// room. The caller also needs it: a dialog that is still on screen
    /// must keep its registry entry, or the card is withdrawn and the
    /// dialog becomes unreachable until a new window opens.
    case success(message: String, dialogGone: Bool)
    case notFound(message: String)
    case forbidden(message: String)
    case accessibilityError(message: String)
}

/// ButtonPresser handles pressing buttons in dialogs and sheets.
/// It respects the Policy and refuses to press dangerous buttons.
public struct ButtonPresser {
    private let policy: Policy
    private let serialiser: DialogSerialiser

    public init(policy: Policy) {
        self.policy = policy
        self.serialiser = DialogSerialiser()
    }

    /// Attempt to press a button by label in the given dialog element.
    ///
    /// The dangerous-label list is a rule about pressing a button NOBODY
    /// asked for — it is why `Policy.evaluate` refuses to auto-answer one.
    /// `humanApproved` means the person read this exact button's name on
    /// their phone and tapped it, and for a high-risk option answered "Are
    /// you sure?" on top of that. Applying the list there refused the press
    /// anyway: "Delete Group" contains "delete", so Chrome's close-tab-group
    /// sheet could not be answered from the phone however many times you
    /// confirmed it, and the same held for every "Send", "Trust", "Grant"
    /// and "Erase" button on the Mac. The approval gate is what makes those
    /// safe; refusing after it has been passed is the app not doing its job.
    public func pressButton(in dialogElement: AXUIElement, withLabel label: String,
                            humanApproved: Bool = false) async -> ButtonPressResult {
        // Resolve FIRST, then judge what was resolved.
        //
        // The guard used to test the requested label while the press used
        // whatever that label resolved to, so the two could disagree: a
        // card offering "Allow" against a sheet that had since become
        // "Allow Always" passed the check on "Allow" and pressed a
        // standing grant. Whatever is about to be pressed is what the
        // policy has to see.
        guard let found = serialiser.findButton(in: dialogElement, withTitle: label) else {
            return .notFound(message: "Button with label '\(label)' not found in dialog")
        }

        if !humanApproved, policy.dangerousButtonLabels.contains(where: { dangerous in
            found.title.lowercased().contains(dangerous.lowercased())
        }) {
            return .forbidden(message: "Button label '\(found.title)' is forbidden by policy")
        }

        // Nobody in the room, so the RESOLVED title has to be one jev
        // recognises as harmless — not the one the card was printed
        // with.
        //
        // `Runtime.refuseToAutoPress` already applies this rule, but it
        // applies it to `chosen.label`, frozen at serialise time, while
        // the press resolves against the live tree and `chooseButton`'s
        // prefix tier will happily return a longer label. Measured: a
        // gate that passed on "Close" pressed "Close Without Saving";
        // on "Stay", "Stay and Empty Trash"; on "Cancel", "Cancel
        // Subscription". None of those contain a `dangerousButtonLabels`
        // substring, so the check above waved them through — which is
        // the exact hazard the comment at the top of this function
        // describes, one layer up.
        // The person tapped a button with a name on it. Press THAT one.
        //
        // Both gates below are `!humanApproved`, so a tap from the phone
        // had nothing comparing what was asked for with what was
        // resolved — and `chooseButton`'s prefix tier will promote a
        // request. Measured against the live matcher: "Allow" resolves
        // to "Allow Always", "Continue" to "Continue Anyway", "Delete"
        // to "Delete Everything", "Send" to "Send to Everyone". Every
        // one of those is refused on the auto path and was allowed on
        // the human one, which is backwards: the auto path has a model
        // behind it, the human path has a person reading a word.
        //
        // If the sheet has relabelled since the card was made, the
        // button the person read no longer exists, and refusing is the
        // honest answer. It also keeps the phone's toast true, since it
        // names the label it sent.
        if humanApproved,
           DialogSerialiser.normalisedTitle(found.title)
             != DialogSerialiser.normalisedTitle(label) {
            return .notFound(message: "That button now reads “\(found.title)” — "
                + "check the Mac before answering")
        }

        if !humanApproved, !DialogWatcher.isKnownSafeLabel(found.title) {
            return .forbidden(message: "“\(found.title)” is not one jev presses on its own")
        }

        return await pressElement(found.element, label: found.title, dialog: dialogElement)
    }

    /// Press a button element directly.
    private func pressElement(_ button: AXUIElement, label: String,
                              dialog: AXUIElement) async -> ButtonPressResult {
        let error = AXUIElementPerformAction(button, kAXPressAction as CFString)

        switch error {
        case .success:
            if await dialogSurvived(dialog) {
                return .success(
                    message: "Pressed “\(label)” — but the dialog is still on screen. "
                        + "If it is a macOS permission prompt, only the Mac's own keyboard "
                        + "or trackpad can answer it.",
                    dialogGone: false)
            }
            return .success(message: "Pressed button '\(label)'", dialogGone: true)
        case .failure:
            return .accessibilityError(message: "General accessibility failure")
        case .apiDisabled:
            return .accessibilityError(message: "Accessibility API is disabled")
        case .noValue:
            return .accessibilityError(message: "Button has no press action available")
        case .attributeUnsupported:
            return .accessibilityError(message: "Press action not supported on this button")
        case .actionUnsupported:
            return .accessibilityError(message: "Button does not support the press action")
        case .invalidUIElement:
            return .accessibilityError(message: "Invalid UI element")
        case .invalidUIElementObserver:
            return .accessibilityError(message: "Invalid UI element observer")
        case .notImplemented:
            return .accessibilityError(message: "Press action not implemented")
        case .notificationUnsupported:
            return .accessibilityError(message: "Notification not supported")
        case .notificationAlreadyRegistered:
            return .accessibilityError(message: "Notification already registered")
        case .notificationNotRegistered:
            return .accessibilityError(message: "Notification not registered")
        case .illegalArgument:
            return .accessibilityError(message: "Invalid argument to press action")
        case .cannotComplete:
            return .accessibilityError(message: "Cannot complete press action")
        case .parameterizedAttributeUnsupported:
            return .accessibilityError(message: "Parameterized attribute not supported")
        case .notEnoughPrecision:
            return .accessibilityError(message: "Not enough precision")
        @unknown default:
            return .accessibilityError(message: "Unknown accessibility error")
        }
    }

    /// Is the DIALOG still there a moment after the press?
    ///
    /// The button is the wrong thing to watch, measured three ways on
    /// this Mac by driving `AXPress` cross-process:
    ///
    ///                              window invalid   button invalid
    ///   NSAlert, accessory app        9 ms           never (>3 s)
    ///   NSAlert, regular app         12 ms           ~700 ms
    ///   beginSheetModal sheet       287 ms           287 ms
    ///
    /// AppKit drains an alert's view hierarchy on its own schedule, and
    /// for a plain modal it may never invalidate the button at all — so
    /// watching the button burned the whole deadline and then reported
    /// "the dialog is still on screen" for a press that had closed it.
    /// The phone showed a red toast telling the person to walk to their
    /// Mac, the audit line recorded `landed: no`, and on the auto-press
    /// path it raised a card AND a push, all for a Cancel that worked.
    /// No deadline fixes that; the element was wrong.
    ///
    /// The window answers in about ten milliseconds in every shape, and
    /// it is what `DialogRegistry.isLive` already watches for exactly
    /// this reason.
    ///
    /// Polled, not slept through: a single fixed wait has to be both
    /// short enough not to stall every answer and long enough for the
    /// slowest app, and no number is both.
    ///
    /// It errs toward saying "still there": a press that did work and
    /// was merely slow gets an honest-but-cautious sentence, where the
    /// opposite error reports a press that never happened as done.
    ///
    /// KNOWN LIMIT, measured: this asks "did the dialog go away?", not
    /// "did the press do it". A dialog that closes for its own reasons
    /// in the same moment — the operation it was reporting finished,
    /// the parent window went away — reads as a press that landed, even
    /// when the button was inert. There is no signal available that
    /// separates the two, and the alternative (never claiming a press
    /// landed) is worse. Written down rather than papered over.
    private func dialogSurvived(_ dialog: AXUIElement) async -> Bool {
        // Who owns it. (An earlier comment here claimed this was read
        // "before the press has a chance to take the process with it",
        // which is not the ordering the code has — `pressElement`
        // presses first and calls this after. Measured harmless:
        // `AXUIElementGetPid` still returns the right pid after the
        // owner has exited. The claim is removed rather than the line
        // moved, because the line is in the right place.)
        var ownerPid: pid_t = 0
        let haveOwner = AXUIElementGetPid(dialog, &ownerPid) == .success

        let clock = ContinuousClock()
        let start = clock.now
        while clock.now - start < .milliseconds(750) {
            do {
                // `await`, not `Thread.sleep`. This runs on the Swift
                // concurrency pool, and parking one of its threads on
                // every answered dialog is paid by everything behind it.
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                // Cancelled. `try?` here spun the rest of the deadline as
                // a hot loop of synchronous AX calls. Bail out on the
                // cautious side instead.
                return true
            }
            var role: AnyObject?
            let error = AXUIElementCopyAttributeValue(
                dialog, kAXRoleAttribute as CFString, &role)
            // Only this one means the element is gone. `cannotComplete`
            // above all does NOT — it is a TIMEOUT from an app busy on
            // its main thread (measured: ~1.5 s), and `DialogRegistry`
            // already spells out that it is not a death certificate.
            if error == .invalidUIElement { return false }

            // An app that quits when its own alert is dismissed — an
            // installer's last sheet, a one-shot helper — leaves BOTH
            // the window and the button answering `cannotComplete`,
            // which is the code a busy app returns and which this loop
            // deliberately reads as "still there". Measured: with a
            // holder that exits on dismissal, window and button both
            // went to -25204; with one that stays up, the window went
            // to -25202 and the button stayed at 0.
            //
            // So when the answer is ambiguous, ask a question that is
            // not: is the process still running? If it is not, nothing
            // of its is on screen.
            //
            // `kill(pid, 0)`, not `NSRunningApplication`. The latter is
            // not a liveness oracle: measured, it returns nil for pid 1,
            // for WindowServer and for every other live process that is
            // not a session app, so "it is not an NSRunningApplication"
            // does not mean "it is gone". Only the watcher's own
            // reachability rules kept that from being wrong in practice,
            // and a safety check should not lean on a coincidence.
            if haveOwner, error != .success,
               kill(ownerPid, 0) != 0, errno == ESRCH { return false }
        }
        return true
    }
}