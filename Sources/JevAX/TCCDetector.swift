import Foundation
import ApplicationServices

/// TCCDetector identifies TCC (Transparency, Consent, and Control) consent sheets.
/// These sheets cannot be clicked via synthetic input and must be handed off to the human.
public struct TCCDetector {
    /// Bundle ids whose windows really are system consent sheets.
    ///
    /// One entry, matched whole. Every other candidate was measured and
    /// removed, because being on this list is DECISIVE — no text check,
    /// no button check — and a wrong entry turns an ordinary window into
    /// a buttonless card plus a push notification that no "never allow
    /// this app" rule can silence, because `handoffOnly` deliberately
    /// skips that rule.
    ///
    ///   * `com.apple.finder` — Finder raises no TCC prompts, and every
    ///     ordinary "are you sure you want to delete" sheet became
    ///     unanswerable. (It was matched by substring, which is also why
    ///     these are whole ids now.)
    ///   * `com.apple.controlcenter` — measured on this Mac: opening
    ///     Control Center puts up an `AXWindow`/`AXSystemDialog` owned by
    ///     exactly this bundle id. Changing the volume sent a push
    ///     reading "Control Center" and a card saying Apple would not
    ///     accept a press. That trains you to ignore the one channel
    ///     this app exists for.
    ///   * `com.apple.usernotificationcenter` — the legacy alert agent.
    ///     It hosts consent sheets, but it also hosts any app's
    ///     `CFUserNotification` alert, and those are ordinary pressable
    ///     dialogs.
    ///   * `com.apple.tccd` — measured: `tccd` runs, but it is not an
    ///     `NSRunningApplication`, so `processDialog` resolves a window
    ///     it owns to "unknown.bundle" and this entry could never match.
    ///     Keeping it made the list look like it covered more than it did.
    ///   * `com.apple.usernotificationcenter` — moved to
    ///     `consentAgentBundleIds` below rather than deleted. Deleting it
    ///     outright was wrong, and measured to be wrong: it is the
    ///     process that actually owns the ordinary consent sheets.
    ///
    /// KNOWN GAP, measured: the one entry left is currently unreachable.
    /// An admin-authorization prompt presents as
    /// `AXWindow`/**`AXStandardWindow`**, and `DialogWatcher.dialogSubroles`
    /// accepts only `AXDialog` and `AXSystemDialog`, so `processDialog`
    /// never runs and this set is never consulted. Widening that filter
    /// to reach it would let every ordinary window through, which is the
    /// Control Center mistake again — and a SecurityAgent prompt cannot
    /// be answered from the phone anyway, so what is lost is a
    /// notification, not an action. Left correct and unreachable, and
    /// written down, rather than papered over.
    private static let tccBundleIds: Set<String> = [
        // Authentication sheets — the admin password, the keychain
        // unlock. These refuse synthetic input at the window-server
        // level, so pressing them from the phone cannot work and saying
        // otherwise is the lie worth avoiding.
        "com.apple.securityagent",
    ]

    /// The agents that raise consent sheets.
    ///
    /// Not decisive on their own — they need the system's own buttons
    /// beside them — but they need no particular wording, and that is
    /// the correction. Measured, from this Mac's
    /// `TCC.framework/…/Localizable.loctable`: there are 48 English
    /// `REQUEST_ACCESS_SERVICE_*` strings, they are worded a dozen
    /// different ways ("would like to access", "would like to capture",
    /// "wants access to control", "Allow “%@” to use Personal Voice?",
    /// "Would you like to allow…"), and the previous attempt to list the
    /// wordings caught 25 of them. The other 23 — screen recording,
    /// administering the computer, modifying apps, passkeys, Photos,
    /// system audio, remote control — arrived as ordinary cards whose
    /// buttons do nothing, and their text was sent to the remote decider
    /// for an answer, which is the one thing `Runtime.handle` short-
    /// circuits `handoffOnly` to prevent.
    ///
    /// What all 48 DO share is the button pair: `REQUEST_ACCESS_DENY` is
    /// "Don’t Allow" in every one of them. So the rule is the owner plus
    /// that button, and the wording is not consulted at all.
    ///
    /// The cost, stated plainly and wider than it first looked:
    /// `UserNotificationCenter` also relays an app's own
    /// `CFUserNotification` alert, so an app whose alert carries one of
    /// these deny words gets treated as a consent sheet and loses its
    /// buttons. And the list is not a private vocabulary — measured,
    /// `["Refuser","Accepter"]`, `["Weiger","Aanvaard"]`,
    /// `["Deny","Approve"]`, `["\u{03AC}\u{03C1}\u{03BD}\u{03B7}\u{03C3}\u{03B7}","\u{0391}\u{03C0}\u{03BF}\u{03B4}\u{03BF}\u{03C7}\u{03AE}"]` all match, and those are
    /// ordinary words for declining a call or a cookie banner.
    ///
    /// It only bites for an alert relayed by the legacy agent, and the
    /// trade is deliberate: this side costs a walk to the Mac, the
    /// other side is a permission prompt that silently cannot be
    /// answered at all.
    private static let consentAgentBundleIds: Set<String> = [
        // Measured on a live sheet: pid 720, AXWindow/AXSystemDialog,
        // "“opengrok-pr139” would like to access files on a removable
        // volume.", buttons "Don’t Allow" / "Allow".
        "com.apple.usernotificationcenter",
        // Screen Recording, Accessibility and Input Monitoring warnings.
        "com.apple.accessibility.universalaccessauthwarn",
    ]

    /// Sentences only macOS writes, for a sheet owned by someone else.
    ///
    /// The backstop, not the main route: a consent sheet attributed to a
    /// process on neither bundle list still has to be recognised, and
    /// only its wording is left to go on. Every entry is verbatim from
    /// this Mac's own string tables — `TCC.framework` and
    /// `universalAccessAuthWarn` — and every one names something no app
    /// says about itself.
    ///
    /// The ordinary consent wording ("would like to access the Camera")
    /// is deliberately NOT here. It is what Safari puts on its own
    /// per-site sheets, word for word, and listing it here strips the
    /// buttons off a dialog that presses perfectly well. Those sheets
    /// are caught by their owner instead.
    ///
    /// Two more wordings were left out on purpose:
    ///
    ///   * "would like to find and connect to devices on your local
    ///     network" — searched for twice across every `.strings` and
    ///     `.loctable` on this machine and never found. It was inert.
    ///   * "wants access to control" — the Apple Events prompt, but also
    ///     a sentence an app could plausibly write ("this app wants
    ///     access to control your files"), and a false positive here
    ///     strips a real dialog's buttons. Its distinctive second
    ///     sentence is matched instead.
    private static let tccPromptPatterns = [
        "would like to capture the contents of the system display",
        "would like to administer your computer",
        "would like to modify apps on your mac",
        "would like to access data from other apps",
        // Matches "…record this computer’s screen and audio." only
        // because `matchesTCCPattern` folds the curly apostrophe.
        "would like to record this computer's screen",
        "would like to control this computer using accessibility features",
        "would like to receive keystrokes from any application",
        "would like to allow for this computer to be controlled remotely",
        "allowing control will provide access to",
    ]

    /// The deny button macOS puts on its own consent sheets, in every
    /// language it ships.
    ///
    /// Not a guess and not a translation: these are the 42 distinct
    /// values of `REQUEST_ACCESS_DENY` / `REQUEST_ACCESS_DONT_ALLOW`
    /// across the 42 languages in this Mac's own
    /// `TCC.framework/…/Localizable.loctable`.
    ///
    /// The list used to be `["don't allow", "deny"]`, and that was
    /// tolerable while an owning bundle id could decide a sheet on its
    /// own. It stopped being tolerable the moment the button check
    /// became mandatory for every route: with an English-only list,
    /// a German Mac detected NO consent sheet at all — measured,
    /// `„Zoom“ möchte auf die Kamera zugreifen.` with
    /// `["Nicht erlauben", "Erlauben"]` came back false — so the sheet
    /// arrived as an ordinary card with buttons macOS ignores, and its
    /// text went to the remote decider, which is the one thing the
    /// handoff short-circuit exists to prevent.
    ///
    /// "Deny" stays on the end: it is not in this table (it belongs to
    /// the accessibility and screen-recording warnings) and it is the
    /// other button macOS writes.
    private static let systemDenyTitles: Set<String> = Set([
        "Don't Allow",
        "Don\u{2019}t Allow",
        "Ikke tillat",
        "Jangan Benarkan",
        "Jangan Izinkan",
        "Ne dovoli",
        "Ne pas autoriser",
        "Nem enged\u{00E9}lyezem",
        "Nemoj dozvoliti",
        "Nepovoli\u{0165}",
        "Nepovolovat",
        "Nicht erlauben",
        "Nie pozwalaj",
        "No permetis",
        "No permitir",
        "Non consentire",
        "Nu permite\u{021B}i",
        "N\u{00E3}o Permitir",
        "N\u{00E3}o permitir",
        "Refuser",
        "Sta niet toe",
        "Tillad ikke",
        "Till\u{00E5}t inte",
        "Tilt\u{00E1}s",
        "T\u{1EEB} ch\u{1ED1}i",
        "Weiger",
        "\u{00C4}l\u{00E4} salli",
        "\u{0130}zin Verme",
        "\u{0386}\u{03C1}\u{03BD}\u{03B7}\u{03C3}\u{03B7}",
        "\u{039D}\u{03B1} \u{03BC}\u{03B7}\u{03BD} \u{03B5}\u{03C0}\u{03B9}\u{03C4}\u{03C1}\u{03B1}\u{03C0}\u{03B5}\u{03AF}",
        "\u{0417}\u{0430}\u{0431}\u{043E}\u{0440}\u{043E}\u{043D}\u{0438}\u{0442}\u{0438}",
        "\u{0417}\u{0430}\u{043F}\u{0440}\u{0435}\u{0442}\u{0438}\u{0442}\u{044C}",
        "\u{041D}\u{0435} \u{0434}\u{043E}\u{0437}\u{0432}\u{043E}\u{043B}\u{044F}\u{0442}\u{0438}",
        "\u{041D}\u{0435} \u{0440}\u{0430}\u{0437}\u{0440}\u{0435}\u{0448}\u{0430}\u{0442}\u{044C}",
        "\u{05E1}\u{05D9}\u{05E8}\u{05D5}\u{05D1}",
        "\u{0639}\u{062F}\u{0645} \u{0627}\u{0644}\u{0633}\u{0645}\u{0627}\u{062D}",
        "\u{0905}\u{0928}\u{0941}\u{092E}\u{0924}\u{093F} \u{0928} \u{0926}\u{0947}\u{0902}",
        "\u{0E44}\u{0E21}\u{0E48}\u{0E2D}\u{0E19}\u{0E38}\u{0E0D}\u{0E32}\u{0E15}",
        "\u{4E0D}\u{5141}\u{8A31}",
        "\u{4E0D}\u{5141}\u{8BB8}",
        "\u{8A31}\u{53EF}\u{3057}\u{306A}\u{3044}",
        "\u{D5C8}\u{C6A9} \u{C548} \u{D568}",
        "Deny",
    ].map(normalisedButton))

    /// Do these buttons belong to macOS rather than to the app?
    ///
    /// A TCC sheet always offers a system deny button beside at least one
    /// way of saying yes. Paired with the phrase list this is what
    /// separates the system's sheet from an app's own — and the phrase
    /// alone cannot, because "would like to access your files" is
    /// ordinary English that an app is free to put in a pressable dialog.
    ///
    /// The button list is every language macOS ships; the WORDING
    /// backstop above is still English only. So on a non-English Mac a
    /// consent sheet is recognised when an agent on the owner list
    /// raised it — which is 39 of the 45 measured prompts — and missed
    /// when it was raised by anything else. That is a real gap and it
    /// is smaller than it was, not closed.
    ///
    /// An earlier version of this comment claimed "the bundle-id branch
    /// is language-independent", which was true when a bundle id alone
    /// could decide a sheet and false the moment the buttons became
    /// mandatory. It is left here as a note that a comment can outlive
    /// the code it describes.
    /// Is this button macOS's own "no", in any language it ships?
    ///
    /// Exposed because refusing is the one answer that is safe in every
    /// language, and the auto-press gate needs to know it.
    public static func isSystemDeny(_ title: String) -> Bool {
        systemDenyTitles.contains(normalisedButton(title))
    }

    public static func looksLikeConsentButtons(_ titles: [String]) -> Bool {
        let named = titles.map(normalisedButton).filter { !$0.isEmpty }
        // A deny with nothing to deny is not a consent sheet.
        guard named.count >= 2 else { return false }
        return named.contains { systemDenyTitles.contains($0) }
    }

    /// Lowercased, trimmed, with the curly apostrophe macOS actually types
    /// folded to the straight one and a trailing ellipsis dropped.
    private static func normalisedButton(_ title: String) -> String {
        title
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{2026}."))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// Detect if a dialog is a macOS consent sheet.
    ///
    /// `dialogText` is the text `DialogSerialiser` already read off this
    /// window — the same text the card shows the person. This used to
    /// walk the tree a second time with a narrower collector of its own
    /// (two attributes, 20 children per level, no element budget, and no
    /// early exit), which read less, cost more, and could disagree with
    /// the card about what the sheet said.
    public static func isTCCDialog(
        dialogText: String,
        processName: String?,
        buttonTitles: [String]
    ) -> Bool {
        isConsentSheet(owner: processName, text: dialogText, buttonTitles: buttonTitles)
    }

    /// The whole decision, with the accessibility tree already read.
    ///
    /// Driven directly by `SelfTest.checkConsentSheet`, using the sheet
    /// measured on this Mac and the Safari sheet it must not be confused
    /// with.
    public static func isConsentSheet(
        owner rawOwner: String?, text: String, buttonTitles: [String]
    ) -> Bool {
        let owner = rawOwner?.lowercased()
        if let owner, tccBundleIds.contains(owner) { return true }

        // Everything below needs the system's own buttons. This is also
        // what keeps Safari out: its per-site sheets are worded exactly
        // like the system's and carry the same two buttons, but they
        // belong to `com.apple.Safari`, which is on neither list.
        guard looksLikeConsentButtons(buttonTitles) else { return false }

        // An agent that raises consent sheets, holding up the system's
        // own buttons. No wording test — all 48 of them are worded
        // differently, and listing the wordings caught half.
        if let owner, consentAgentBundleIds.contains(owner) { return true }

        // Owned by something else: the wording is all that is left.
        return matchesTCCPattern(text, tccPromptPatterns)
    }

    private static func matchesTCCPattern(_ text: String, _ patterns: [String]) -> Bool {
        // macOS types the curly apostrophe, the patterns are written with
        // the straight one, and "computer\u{2019}s screen" does not contain
        // "computer's screen" — the whole list would have been inert.
        let lowercased = text
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .lowercased()
        return patterns.contains { pattern in
            lowercased.contains(pattern.lowercased())
        }
    }
}
