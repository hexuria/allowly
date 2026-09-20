import Foundation

public struct SelfTest {
    /// Run self-contained sanity checks on the domain model.
    /// Returns an array of failure descriptions (empty if all pass).
    public static func run() -> [String] {
        var failures: [String] = []

        failures.append(contentsOf: testStrictDefaultPolicyEscalatesUnknownApp())
        failures.append(contentsOf: testDangerousButtonLabelNotAutoPressed())
        failures.append(contentsOf: testReplayGuardRejectsDuplicate())
        failures.append(contentsOf: testRiskLevelOrdering())
        failures.append(contentsOf: testNonceValidation())
        failures.append(contentsOf: testPolicyCommandPrefix())

        return failures
    }

    /// What a card is headed, for the four shapes a dialog comes in.
    ///
    /// This lives here rather than in JevAX because it needs no AX at all —
    /// which is the point. Three attempts at this shipped wrong, each
    /// visible in one worked example, and none of them had a test.
    public static func checkHeadings(
        _ derive: (String, String, String) -> (title: String, body: String)) -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append("heading: \(name)") }
        }

        // A titled alert. The serialiser puts the title on the header line
        // too, so the naive "is it a bare [role] marker" test missed it and
        // the card said the same sentence three times.
        let titled = derive("[AXSheet] Close Tab?\nClose Tab?\nThis will delete the group.\nBUTTON: Delete Group\nBUTTON: Cancel",
                            "Close Tab?", "Google Chrome")
        check("a titled alert is headed by its title", titled.title == "Close Tab?")
        check("the role never reaches the body", !titled.body.contains("AXSheet"))
        check("the heading is not repeated in the body", !titled.body.contains("Close Tab?"))
        check("the body keeps what it actually says",
              titled.body == "This will delete the group.")

        // A sheet whose only content is its buttons. Heading it
        // "BUTTON: Delete Group" reads like an instruction.
        let buttonsOnly = derive("[AXSheet]\nBUTTON: Delete Group\nBUTTON: Cancel", "", "Google Chrome")
        check("a button-only sheet falls back to the app", buttonsOnly.title == "Google Chrome")
        check("a button-only sheet has no body", buttonsOnly.body.isEmpty)

        // Text but no AXTitle: the first real line is the heading.
        let untitled = derive("[AXSheet]\nAre you sure?\nThis cannot be undone.\nBUTTON: OK",
                              "", "Finder")
        check("an untitled sheet is headed by its first line", untitled.title == "Are you sure?")
        check("and keeps the rest", untitled.body == "This cannot be undone.")

        // A body that legitimately says the heading twice keeps the second.
        let twice = derive("[AXSheet] Leave site?\nLeave site?\nLeave site?\nBUTTON: Leave",
                           "Leave site?", "Google Chrome")
        check("only one repeat of the heading is dropped", twice.body == "Leave site?")

        // Whitespace on the AXTitle must not defeat the comparison.
        let padded = derive("[AXSheet]  Close Tab? \nClose Tab?\nBody.", "  Close Tab? ", "Chrome")
        check("a padded title still matches its repeat", padded.body == "Body.")

        // CRLF. Swift treats "\r\n" as ONE grapheme, so splitting on "\n"
        // alone left the whole dialog as a single line — which then looked
        // like the header and was removed entire. The card came out with
        // the app's name and no body: approve this thing I will not tell
        // you about.
        let crlf = derive("[AXSheet] Close Tab?\r\nClose Tab?\r\nThis will delete the group.\r\nBUTTON: Delete",
                          "Close Tab?", "Google Chrome")
        check("CRLF text still has a body", crlf.body == "This will delete the group.")
        check("CRLF text is headed by its title", crlf.title == "Close Tab?")

        // The header goes by POSITION. Testing its shape ate a real body
        // line whenever the header itself came back empty.
        let bracketed = derive("\n[Beta] This build expires tomorrow.\nBUTTON: OK", "", "Chrome")
        check("a body line starting with a bracket survives",
              bracketed.title == "[Beta] This build expires tomorrow.")

        // The same heading in a different case is the same heading.
        let cased = derive("[AXSheet] Leave site?\nleave site?\nYour changes are unsaved.",
                           "Leave site?", "Chrome")
        check("a differently-cased repeat is still a repeat",
              cased.body == "Your changes are unsaved.")

        // Nothing at all still produces something to read.
        let nothing = derive("[AXWindow]", "", "")
        check("there is always a heading", !nothing.title.isEmpty)
        // Widget furniture is filtered by the SERIALISER now, not by
        // the heading — see `checkWidgetNoise`. What the heading still
        // owns is an AXTitle that names the widget rather than the
        // question.

        let named = derive("[AXSheet] \nLeaving discards your draft.\nBUTTON: Leave",
                            "Leave site?", "Safari")
        check("a real AXTitle is still preferred", named.title == "Leave site?")

        let bare = derive("[AXWindow] \nSomething happened.", "TestApp", "TestApp")
        check("an AXTitle that is just the app name steps aside",
              bare.title == "Something happened.")

        return failures
    }

    /// Which button a tap presses, when two labels look alike.
    ///
    /// Nine review rounds walked past this. The matcher tested
    /// `a.contains(b) || b.contains(a)` in BOTH directions and took the
    /// first hit in tree order, so on the commonest sheet on macOS one of
    /// the two buttons was always wrong — and it reported success either
    /// way. In every such pair the loose match favours the more damaging
    /// option.
    /// Is this line the name of a widget, or something a person said?
    ///
    /// The rule that decides whether a line of a dialog reaches the
    /// card. It is applied to an element's DESCRIPTION only — a
    /// description labels the widget, a static text's value is the
    /// message — and getting that distinction wrong blanked the card
    /// on a stock alert whose entire message was "Security Alert".
    public static func checkWidgetNoise(_ isNoise: (String, String) -> Bool) -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append("noise: \(name)") }
        }

        // Measured off live AX trees on this Mac.
        for furniture in ["alert", "warning icon", "application icon",
                          "liveholder.bin alert", "print dialog", "New Window"] {
            check("\u{201c}\(furniture)\u{201d} is furniture", isNoise(furniture, ""))
        }

        // Things a person wrote. Three words, or ending like a sentence.
        for message in ["Close this window", "Do you want to delete this?",
                        "Delete all 412 messages in this mailbox?",
                        "Your session will end:", "Quit without saving?"] {
            check("\u{201c}\(message)\u{201d} is not furniture", !isNoise(message, ""))
        }

        // KNOWN COST, asserted so it stays a decision and not a
        // surprise: a two-word message ending in a widget word reads as
        // furniture. It is only ever applied to a description, so a real
        // alert saying this in its static text is unaffected.
        check("a two-word widget phrase is treated as furniture",
              isNoise("Security Alert", ""))

        // AppKit composes an alert icon's description as "<app name>
        // alert". A two-word rule caught "liveholder.bin alert" and
        // missed every app with a space in its name — Google Chrome,
        // Microsoft Word, Visual Studio Code — so the card's heading
        // and the push body became "Google Chrome alert".
        for app in ["Google Chrome", "Microsoft Word", "Visual Studio Code",
                    "System Settings", "Jev Test Harness"] {
            check("\u{201c}\(app) alert\u{201d} is furniture when the app is known",
                  isNoise("\(app) alert", app))
        }
        // …and the name alone does not make real text disappear.
        check("a real message from a multi-word app survives",
              !isNoise("Delete all 412 messages in this mailbox?", "Google Chrome"))
        check("a message that merely starts with the app name survives",
              !isNoise("Google Chrome wants to restart to update", "Google Chrome"))

        return failures
    }

    /// Does a driver's reason string give the typed value back?
    ///
    /// The gate that decides whether a typed value is redacted before
    /// it reaches `commands.jsonl`, which `/api/journal` serves. It was
    /// an exact substring test, so any echo the driver had reshaped —
    /// trimmed, case-folded, truncated to fit — read as "this reason is
    /// jev's own" and skipped the redaction.
    public static func checkReasonEcho(
        _ echoes: (String, String) -> Bool) -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append("echo: \(name)") }
        }

        let secret = "hunter2-correct-horse"
        check("a verbatim echo is caught", echoes(secret, "Typed \(secret) into Password"))
        check("a case-folded echo is caught",
              echoes(secret, "Typed HUNTER2-CORRECT-HORSE"))
        check("a trimmed echo is caught", echoes(secret, "Typed  \(secret)  "))
        check("a truncated echo is caught", echoes(secret, "Typed hunter2-corre\u{2026}"))
        check("a re-spaced echo is caught", echoes(secret, "Typed hunter2 - correct - horse"))

        check("jev's own wording is not an echo",
              !echoes(secret, "Typed into \u{201c}Password\u{201d}"))
        // An innocuous value that really does come back IS an echo, and
        // is redacted. The test cannot know "Chrome" was harmless, and
        // erring the other way is how a password reaches the journal.
        check("a value that does come back counts, harmless or not",
              echoes("Chrome", "Typed into Chrome"))
        check("nothing typed is never an echo", !echoes("", "Typed into Password"))

        return failures
    }

    /// What a decision made with nobody in the room may press.
    ///
    /// A positive list, because the negative one was English: on an
    /// en_GB Mac `Empty Bin` and `Move to Bin` rated low, which is the
    /// unattended ceiling, and so did `L\u{00F6}schen` and `Supprimer`.
    public static func checkAutoPressable(
        _ safe: (String) -> Bool) -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append("auto-press: \(name)") }
        }

        for label in ["Cancel", "Not Now", "Later", "Deny", "Don't Allow",
                      "Keep Editing", "Dismiss", "No Thanks"] {
            check("\(label) may be pressed unattended", safe(label))
        }
        // Words that mean "do nothing" on one dialog and "go ahead" on
        // another. "Keep" is the affirmative on a dangerous-download
        // prompt; "Close" discards in apps that name it plainly.
        for label in ["Keep", "Close", "Stay", "Skip", "Ignore", "Keep Both"] {
            check("\u{201c}\(label)\u{201d} is too ambiguous to press unattended", !safe(label))
        }
        // Refusing is safe in every language macOS ships.
        for label in ["Nicht erlauben", "Ne pas autoriser", "No permitir",
                      "\u{8A31}\u{53EF}\u{3057}\u{306A}\u{3044}", "\u{4E0D}\u{5141}\u{8BB8}"] {
            check("the localized refusal may be pressed unattended", safe(label))
        }
        // Everything else has to come to a person, INCLUDING things no
        // English list would flag.
        for label in ["Cancel Subscription", "Close Without Saving", "Stay and Empty Trash",
                      "Keep Dangerous File", "Skip Verification",
                      "Empty Bin", "Move to Bin", "L\u{00F6}schen", "Supprimer",
                      "Vider la corbeille", "Nicht sichern", "Allow", "Delete",
                      "Pay Now", "Erlauben", "", "  "] {
            check("\u{201c}\(label)\u{201d} is not pressed unattended", !safe(label))
        }
        return failures
    }

    /// The sheet that must be handed off, and the one that must not.
    ///
    /// Both of these were measured on a real Mac. The first is a live
    /// consent sheet caught mid-review; the second is Safari's own
    /// per-site sheet, read out of `Safari.framework`'s string table.
    /// They are worded the same and carry the same two buttons, and the
    /// only thing that separates them is who owns the window — which is
    /// exactly what one round got wrong in each direction: first by
    /// marking Safari's sheet unpressable, then by failing to recognise
    /// the system's at all.
    public static func checkConsentSheet(
        _ isConsent: (String?, String, [String]) -> Bool) -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append("consent-sheet: \(name)") }
        }

        let systemButtons = ["Don\u{2019}t Allow", "Allow"]

        // Measured: pid 720, com.apple.UserNotificationCenter,
        // AXWindow/AXSystemDialog.
        let live = "\u{201c}opengrok-pr139\u{201d} would like to access files on a removable volume."
        check("the measured system sheet is a consent sheet",
              isConsent("com.apple.UserNotificationCenter", live, systemButtons))
        check("the bundle id is matched whatever its case",
              isConsent("com.apple.usernotificationcenter", live, systemButtons))

        // Same sentence, same buttons, different owner.
        check("Safari's own camera sheet is NOT a consent sheet",
              !isConsent("com.apple.Safari",
                         "\u{201c}meet.google.com\u{201d} would like to access the camera.",
                         systemButtons))
        check("Safari's own location sheet is NOT a consent sheet",
              !isConsent("com.apple.Safari",
                         "\u{201c}maps.example\u{201d} would like to use your current location.",
                         systemButtons))

        // The family that a wording list could not hold.
        //
        // These are verbatim from this Mac's own
        // `TCC.framework/…/Localizable.loctable`, and 23 of the 48
        // strings in it — these among them — went undetected when the
        // rule was a list of phrasings. Measured after the change: 45
        // of 45 `REQUEST_ACCESS_SERVICE_*` strings are caught with this
        // owner.
        for wording in [
            "\u{201c}Zoom\u{201d} would like to capture the contents of the system display.",
            "\u{201c}1Password\u{201d} would like to administer your computer. Administration can "
                + "include modifying passwords, networking, and system settings.",
            "Would you like to allow \u{201c}Chrome\u{201d} to access and use your saved Passkeys?",
            "Allow \u{201c}Photomator\u{201d} to access your Photo Library?",
            "Allow \u{201c}Reader\u{201d} to use Personal Voice?",
            "\u{201c}Installer\u{201d} would like to modify apps on your Mac.",
            "\u{201c}Audio Hijack\u{201d} would like access to record your system audio.",
            "\u{201c}Calendar\u{201d} would like full access to your Calendar.",
        ] {
            check("the system's own sheet is handed off: \(wording.prefix(34))",
                  isConsent("com.apple.UserNotificationCenter", wording, systemButtons))
        }

        // Wording no app writes about itself stands on its own, whoever
        // owns the window — this is the backstop for a sheet attributed
        // to a process on neither list.
        check("screen recording is a consent sheet, curly apostrophe and all",
              isConsent("com.apple.accessibility.universalAccessAuthWarn",
                        "\u{201c}Zoom\u{201d} would like to record this computer\u{2019}s screen and audio.",
                        systemButtons))
        check("accessibility control is a consent sheet whoever owns it",
              isConsent("com.example.something",
                        "\u{201c}Raycast\u{201d} would like to control this computer using accessibility features.",
                        systemButtons))
        check("administering the computer is a consent sheet whoever owns it",
              isConsent("com.example.something",
                        "\u{201c}X\u{201d} would like to administer your computer.",
                        systemButtons))

        // …but ordinary consent wording from an unlisted owner is NOT.
        // That is the Safari case, and it is why the wording list holds
        // only sentences an app would never write about itself.
        check("plain access wording from an unlisted owner is not enough",
              !isConsent("com.example.something",
                         "\u{201c}X\u{201d} would like to access the Camera.",
                         systemButtons))
        check("an app's own wants-access-to-control is not a consent sheet",
              !isConsent("com.some.app", "This app wants access to control your files",
                         ["Deny", "Allow"]))

        // The buttons are required in every route but the decisive one.
        check("consent wording with an app's own buttons is not a consent sheet",
              !isConsent("com.apple.UserNotificationCenter", live, ["Continue", "Cancel"]))
        // …but the authentication agent is decisive without them.
        check("SecurityAgent is decisive",
              isConsent("com.apple.SecurityAgent", "", []))

        // An ordinary alert relayed by the same agent stays pressable —
        // as long as it uses its own buttons.
        check("an ordinary alert from the alert agent is not a consent sheet",
              !isConsent("com.apple.UserNotificationCenter",
                         "Time Machine could not complete the backup.",
                         ["OK", "Cancel"]))
        // …and this is the documented cost of the owner rule, asserted
        // rather than left as a surprise: an app's own alert that uses
        // the SYSTEM's deny vocabulary is treated as a consent sheet and
        // loses its buttons. The alternative was missing half the real
        // ones, which is worse; this is written down so that a future
        // round changing it knows it is changing a decision, not fixing
        // an oversight.
        check("an app's alert wearing the system's buttons is caught, deliberately",
              isConsent("com.apple.UserNotificationCenter",
                        "Time Machine could not complete the backup.",
                        ["Don\u{2019}t Allow", "Allow"]))

        return failures
    }

    /// High risk is the gate, not a mood.
    ///
    /// A high option asks "are you sure?" before anything is sent, and a
    /// spoken answer will not act on one at all. Anything that destroys
    /// work therefore has to rate high, or a misheard word spends it.
    public static func checkRisk(
        _ risk: (String) -> RiskLevel) -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append("risk: \(name)") }
        }

        // Losing work is high. This is the half that was missing.
        check("Discard is high", risk("Discard") == .high)
        check("Discard Changes is high", risk("Discard Changes") == .high)
        check("Don't Save is high", risk("Don't Save") == .high)
        check("the curly Don\u{2019}t Save is high too",
              risk("Don\u{2019}t Save") == .high)
        check("Revert is high", risk("Revert") == .high)
        check("Replace is high", risk("Replace") == .high)
        check("Move to Trash is high", risk("Move to Trash") == .high)

        // Granting is high, and always was.
        check("Allow is high", risk("Allow") == .high)
        check("Delete Group is high", risk("Delete Group") == .high)

        // Losing work by another spelling.
        check("Close Without Saving is high", risk("Close Without Saving") == .high)
        check("Quit Without Saving is high", risk("Quit Without Saving") == .high)
        check("Clear History is high", risk("Clear History") == .high)
        check("Forget This Network is high", risk("Forget This Network") == .high)

        // A negation inverts the word it is in front of…
        check("Don't Replace is low", risk("Don't Replace") == .low)
        check("Don't Delete is low", risk("Don't Delete") == .low)
        // …except for the one that still loses the document.
        check("Don't Save stays high", risk("Don't Save") == .high)

        // Spending money and granting access.
        for label in ["Pay", "Pay Now", "Subscribe", "Confirm", "Submit",
                      "Approve", "Authorize", "Accept", "I Agree", "Turn Off"] {
            check("\(label) is high", risk(label) == .high)
        }
        // …and the word that contains its own opposite.
        check("Disagree is low", risk("Disagree") == .low)

        // Negation is a rule, not a list, so these need no entry of
        // their own.
        for label in ["Don't Disable", "Don't Empty Trash", "Don't Log Out",
                      "Never Allow", "Not Trusted", "Do Not Send",
                      "Don't Turn Off", "Don't Pay"] {
            check("\(label) is low", risk(label) == .low)
        }
        check("Don't Restore still loses what was recovered",
              risk("Don't Restore") == .high)
        check("Don't Keep discards", risk("Don't Keep") == .high)

        // A short word inside a longer one is not that word.
        for label in ["Block Cookies", "Look Up", "Add Bookmark", "Payment Details"] {
            check("\(label) is low", risk(label) == .low)
        }
        check("Unsubscribe is low", risk("Unsubscribe") == .low)
        check("Subscribe itself is still high", risk("Subscribe") == .high)
        check("OK on its own is still medium", risk("OK") == .medium)

        // The ones an English-only list rated safe.
        check("Force Quit is high", risk("Force Quit") == .high)
        check("Quit Anyway is high", risk("Quit Anyway") == .high)
        check("Turn On is high", risk("Turn On") == .high)
        check("Empty Bin is high", risk("Empty Bin") == .high)
        check("Move to Bin is high", risk("Move to Bin") == .high)

        // The ones a short-circuit or a prefix got wrong.
        check("Okay is medium", risk("Okay") == .medium)
        check("Empty the Bin is high", risk("Empty the Bin") == .high)
        check("Unsubscribe and Delete Account is high",
              risk("Unsubscribe and Delete Account") == .high)
        check("Disagree and Delete is high", risk("Disagree and Delete") == .high)
        check("Never Save Passwords is low", risk("Never Save Passwords") == .low)
        check("Don't Save is still high", risk("Don't Save") == .high)
        check("Don't Save Changes is still high", risk("Don't Save Changes") == .high)

        // Declining is safe, and used to cost a confirmation.
        check("Don't Allow is low", risk("Don't Allow") == .low)
        check("Don\u{2019}t Allow is low with the curly one too",
              risk("Don\u{2019}t Allow") == .low)
        check("Don't Trust is low", risk("Don't Trust") == .low)
        check("Allow itself is still high", risk("Allow") == .high)

        // A deferral that still acts is not a deferral.
        check("Send Later is high", risk("Send Later") == .high)
        check("Delete and Keep Both is high", risk("Delete and Keep Both") == .high)

        // Putting something off does nothing.
        check("Restart Later is low", risk("Restart Later") == .low)
        check("Remind Me Later is low", risk("Remind Me Later") == .low)
        check("Restart itself is still high", risk("Restart") == .high)

        // The safe words stay answerable without a second tap.
        check("Cancel is low", risk("Cancel") == .low)
        check("Keep Editing is low", risk("Keep Editing") == .low)
        check("Not Now is low", risk("Not Now") == .low)
        check("Save is medium", risk("Save") == .medium)

        return failures
    }

    /// A consent sheet is the system's, or it is the app's.
    ///
    /// Injected because the detector lives in JevAX, which JevCore
    /// cannot see. The wrong answer either way is a real cost: too
    /// eager and an ordinary dialog loses its buttons and the person
    /// is told a lie about why; too shy and a real consent sheet
    /// arrives with buttons macOS will ignore.
    public static func checkConsentButtons(
        _ looksLikeConsent: ([String]) -> Bool) -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append("consent: \(name)") }
        }

        // The sheets macOS actually draws.
        check("camera prompt", looksLikeConsent(["Don't Allow", "OK"]))
        check("notification prompt", looksLikeConsent(["Allow", "Don't Allow"]))
        check("photos prompt",
              looksLikeConsent(["Limit Access\u{2026}", "Allow Full Access", "Don't Allow"]))
        check("screen recording prompt",
              looksLikeConsent(["Open System Settings", "Deny"]))
        // macOS types the curly one.
        check("a curly apostrophe is still the system's deny",
              looksLikeConsent(["Don\u{2019}t Allow", "Allow"]))
        check("case and padding do not matter",
              looksLikeConsent([" allow ", "  DON'T ALLOW"]))

        // The app's own dialogs, worded to look the same.
        check("Cancel is not a system deny",
              !looksLikeConsent(["Allow", "Cancel"]))
        check("No thanks is not a system deny",
              !looksLikeConsent(["Continue", "No Thanks"]))
        check("an ordinary save sheet is not a consent sheet",
              !looksLikeConsent(["Save", "Don't Save", "Cancel"]))
        // A deny with nothing to deny is not a sheet at all.
        check("one lone button is not a consent sheet",
              !looksLikeConsent(["Don't Allow"]))
        check("no buttons is not a consent sheet", !looksLikeConsent([]))
        check("blank titles do not count toward the pair",
              !looksLikeConsent(["Don't Allow", "   "]))

        // Every language macOS ships, not just the one this Mac is in.
        // The deny list is the whole `REQUEST_ACCESS_DENY` column of the
        // system's own table; with the English-only version, a German
        // Mac detected no consent sheet at all.
        for (language, deny, allow) in [
            ("de", "Nicht erlauben", "Erlauben"),
            ("fr", "Ne pas autoriser", "Autoriser"),
            ("es", "No permitir", "Permitir"),
            ("ja", "\u{8A31}\u{53EF}\u{3057}\u{306A}\u{3044}", "\u{8A31}\u{53EF}"),
            ("zh", "\u{4E0D}\u{5141}\u{8BB8}", "\u{5141}\u{8BB8}"),
            ("ko", "\u{D5C8}\u{C6A9} \u{C548} \u{D568}", "\u{D5C8}\u{C6A9}"),
            ("ru", "\u{041D}\u{0435} \u{0440}\u{0430}\u{0437}\u{0440}\u{0435}\u{0448}\u{0430}\u{0442}\u{044C}",
                   "\u{0420}\u{0430}\u{0437}\u{0440}\u{0435}\u{0448}\u{0438}\u{0442}\u{044C}"),
        ] {
            check("\(language) consent buttons are recognised",
                  looksLikeConsent([deny, allow]))
        }

        return failures
    }

    public static func checkButtonChoice(
        _ choose: (String, [String]) -> String?) -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append("button: \(name)") }
        }

        // The one that loses a document.
        let save = ["Save", "Don't Save", "Cancel"]
        check("Save presses Save", choose("Save", save) == "Save")
        check("Don't Save does NOT press Save", choose("Don't Save", save) == "Don't Save")
        // Tree order must not decide it.
        let reversed = ["Don't Save", "Save", "Cancel"]
        check("Save presses Save whichever order", choose("Save", reversed) == "Save")
        check("Don't Save presses Don't Save whichever order",
              choose("Don't Save", reversed) == "Don't Save")

        // The one that grants more than you meant.
        check("Allow does not press Allow Once",
              choose("Allow", ["Allow Once", "Allow", "Deny"]) == "Allow")
        check("Allow Once does not press Allow",
              choose("Allow Once", ["Allow", "Allow Once", "Deny"]) == "Allow Once")
        // …and the same pair with no exact match to fall back on.
        check("an unmatched wider option is refused, not guessed",
              choose("Allow", ["Allow Once", "Allow Always"]) == nil)

        // The one that deletes more than you meant.
        check("Delete does not press Delete All",
              choose("Delete", ["Delete All", "Delete", "Cancel"]) == "Delete")

        // Curly apostrophes are what macOS actually puts in a button.
        check("a curly apostrophe still matches",
              choose("Don't Save", ["Don\u{2019}t Save", "Save"]) == "Don\u{2019}t Save")
        check("case and padding do not matter",
              choose("  cancel ", ["Save", "Cancel"]) == "Cancel")

        // The prefix tier is what the human path now guards against:
        // these all resolve to something WIDER than what was asked for,
        // which is correct for finding a button and wrong for pressing
        // one on a person's behalf. `ButtonPresser` refuses them when
        // the tap came from the phone; asserted here so the resolutions
        // themselves cannot drift unnoticed.
        check("Allow widens to Allow Always",
              choose("Allow", ["Allow Always", "Don't Allow"]) == "Allow Always")
        check("Continue widens to Continue Anyway",
              choose("Continue", ["Continue Anyway", "Go Back"]) == "Continue Anyway")
        check("Delete widens to Delete Everything",
              choose("Delete", ["Delete Everything", "Cancel"]) == "Delete Everything")
        check("an exact match still beats the wider one",
              choose("Allow", ["Allow", "Allow Always"]) == "Allow")

        // Nothing is not a button.
        check("an empty name presses nothing", choose("", ["Save", "Cancel"]) == nil)
        check("a name that is not there presses nothing",
              choose("Publish", ["Save", "Cancel"]) == nil)

        // The last-resort tiers still work when they are unambiguous.
        check("one partial match is still usable",
              choose("Replace", ["Replace Existing", "Keep Both"]) == "Replace Existing")

        // …but NEVER across a negation, which is the half the first fix
        // missed. On a two-button sheet "Don't Save" is the ONLY
        // candidate containing "Save", so "unambiguous" said yes and
        // returned the opposite of what was asked. Narrowing is fine;
        // inverting is not.
        check("Save does not fall back to Don't Save",
              choose("Save", ["Don't Save", "Cancel"]) == nil)
        check("Allow does not fall back to Don't Allow",
              choose("Allow", ["Don\u{2019}t Allow", "Cancel"]) == nil)
        check("Send does not fall back to Don't Send",
              choose("Send", ["Don't Send", "Cancel"]) == nil)
        // In the languages the secret-field detection already covers.
        check("nicht sichern is not sichern",
              choose("Sichern", ["Nicht sichern", "Abbrechen"]) == nil)
        check("不允许 is not 允许",
              choose("允许", ["不允许", "取消"]) == nil)
        // And the reverse: a negated request still matches a negated
        // candidate, so this does not break what it is meant to allow.
        check("a negated request can still narrow",
              choose("Don't Save", ["Don't Save and Quit", "Save"]) == "Don't Save and Quit")

        // The three shapes an inversion comes in. A marker-word list
        // caught only the first, and measurement found the other two
        // still handing back the opposite of what was asked.
        check("a glued-on prefix is an inversion",
              choose("Install", ["Uninstall", "Cancel"]) == nil
                && choose("Block", ["Unblock", "Cancel"]) == nil
                && choose("Allow", ["Disallow", "Cancel"]) == nil)
        // Anything bolted on the FRONT is refused, inversion or not:
        // "Cancel Download" reverses "Download", and "Approve Invoice"
        // versus "Discard Invoice" is a choice nobody should make for
        // you. One rule covers both.
        check("a word in front is never a narrowing",
              choose("Download", ["Cancel Download", "Keep"]) == nil
                && choose("Invoice", ["Approve Invoice", "Discard Invoice"]) == nil
                && choose("Sharing", ["Stop Sharing"]) == nil)
        check("Korean 하지 않 is an inversion",
              choose("저장", ["저장하지 않음", "취소"]) == nil)

        // …and none of those may refuse a label that merely looks like
        // one. These are the false positives the first list produced.
        check("a word that merely starts with un- is not a negation",
              !Negation.isNegated("Understand") && !Negation.isNegated("Under Review")
                && !Negation.isNegated("Unit") && !Negation.isNegated("Update")
                && !Negation.isNegated("Uninstall"))
        check("Russian words containing не are not negations",
              !Negation.isNegated("Сохранить изменения")
                && !Negation.isNegated("Сохранение"))
        check("Korean 안전 is not a negation", !Negation.isNegated("안전 모드"))
        check("ordinary English labels are not negations",
              !Negation.isNegated("Notes") && !Negation.isNegated("Nothing")
                && !Negation.isNegated("Now") && !Negation.isNegated("Notify")
                && !Negation.isNegated("Password"))
        // A legitimate narrowing in Russian still works.
        check("a Russian narrowing still resolves",
              choose("Сохранить", ["Сохранить изменения", "Отменить"]) == "Сохранить изменения")

        // An ellipsis and three dots are the same title.
        check("an ellipsis matches three dots",
              choose("Save As...", ["Save As\u{2026}", "Cancel"]) == "Save As\u{2026}")
        return failures
    }

    /// Every request path has exactly one spelling.
    ///
    /// Two places disagreed about what `//api/pending` was: the auth check
    /// said "not an API route, no token needed" and the router said "yes,
    /// that is /api/pending" and served it. Every authenticated route was
    /// open to anything that could reach the port, and the shipped phone
    /// app was sending on that exact path the whole time.
    public static func checkPaths(_ canonical: (String) -> String) -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append("path: \(name)") }
        }

        // The bypass itself, in every shape it comes in.
        check("a doubled leading slash collapses", canonical("//api/pending") == "/api/pending")
        check("three do too", canonical("///api/pending") == "/api/pending")
        check("an inner double collapses", canonical("/api//pending") == "/api/pending")
        check("both at once", canonical("//api//decide") == "/api/decide")
        check("the websocket route too", canonical("//ws") == "/ws")

        // …without changing anything that was already right.
        check("an ordinary route is untouched", canonical("/api/pending") == "/api/pending")
        check("the root stays the root", canonical("/") == "/")
        check("a file is untouched", canonical("/app.js") == "/app.js")

        // The query string survives, because the token rides in it on the
        // screenshot poll.
        check("a query survives", canonical("//api/screenshot?t=1") == "/api/screenshot?t=1")
        check("a query with slashes in it is not a path",
              canonical("//api/x?u=https://a//b") == "/api/x?u=https://a//b")
        return failures
    }

    /// The store is an actor, so its checks cannot run inside `run()`.
    public static func runStore() async -> [String] { await testApprovalStore() }

    /// The store's three promises: it does not reap behind your back, an
    /// expired request is unanswerable, and two different dialogs are not
    /// one dialog.
    ///
    /// None of these had a test. Between them they produced a card that
    /// could not be dismissed, a three-hour-old card that still ran its
    /// command, and a second Chrome sheet that never reached the phone at
    /// all because it shared a heading with the first.
    private static func testApprovalStore() async -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append("store: \(name)") }
        }

        func request(_ id: String, title: String, body: String,
                     age: TimeInterval, options: [String] = ["ok"]) -> ApprovalRequest {
            ApprovalRequest(
                id: id, kind: .appDialog, title: title, bodyText: body,
                options: options.map { ApprovalOption(id: $0, label: $0, riskLevel: .low) },
                originatingApp: ApplicationInfo(name: "Chrome", bundleIdentifier: "com.google.Chrome"),
                timestamp: Date().addingTimeInterval(-age),
                screenshotReference: nil, handoffOnly: false)
        }

        let store = ApprovalStore()
        await store.add(request("fresh", title: "Save?", body: "Unsaved changes", age: 1))
        await store.add(request("old", title: "Leave?", body: "Changes will be lost", age: 400))

        // Reading must not remove. Whoever removes has to announce it, and
        // only `reapExpired` does — so a silent reap here left a card on a
        // phone that nothing would ever take down.
        check("reading does not reap", await store.getAllPending().count == 1)
        check("reading still does not reap", await store.getAllPending().count == 1)
        check("counting does not reap", await store.count() == 1)

        // Expired means unanswerable, immediately — not "once the sweep
        // gets to it", because the sweep does not run at all without
        // Accessibility.
        check("an expired request cannot be answered", await store.get(id: "old") == nil)
        check("a live one still can", await store.get(id: "fresh") != nil)

        let reaped = await store.reapExpired()
        check("reaping hands back what it removed",
              reaped.count == 1 && reaped.first?.id == "old")
        check("reaping twice finds nothing", await store.reapExpired().isEmpty)
        check("the live one survived", await store.getAllPending().count == 1)

        // Two untitled sheets from one app are not the same sheet. Both
        // take their app's name as a heading, so keying on the heading
        // alone suppressed the second one entirely.
        let fresh = ApprovalStore()
        check("the first untitled sheet is accepted",
              await fresh.addDeduplicated(request("a", title: "Chrome", body: "Close Tab and Delete Group?",
                                            age: 0, options: ["Delete Group", "Cancel"])))
        check("a DIFFERENT untitled sheet is not a duplicate",
              await fresh.addDeduplicated(request("b", title: "Chrome", body: "Leave site?",
                                            age: 0, options: ["Leave", "Stay"])))
        check("the SAME sheet said twice is a duplicate",
              await !fresh.addDeduplicated(request("c", title: "Chrome", body: "Leave site?",
                                                   age: 0, options: ["Leave", "Stay"])))
        check("same words, different buttons is not a duplicate",
              await fresh.addDeduplicated(request("d", title: "Chrome", body: "Leave site?",
                                            age: 0, options: ["Leave", "Cancel"])))

        // A SPOKEN command is the other way round: its body is the
        // transcript, so three wordings of the same command must still be
        // one card. Keying on the body turned "skip", "click skip" and
        // "press the skip button" into three cards that each clicked Skip.
        func spoken(_ id: String, said: String) -> ApprovalRequest {
            ApprovalRequest(
                id: id, kind: .spokenCommand, title: "Click “Skip”",
                bodyText: "You said “\(said)”.",
                options: [ApprovalOption(id: "once", label: "Once", riskLevel: .low)],
                originatingApp: ApplicationInfo(name: "jev", bundleIdentifier: "system.pointer"),
                timestamp: Date(), screenshotReference: nil, handoffOnly: false)
        }
        let spokenStore = ApprovalStore()
        check("the first way of saying it is accepted",
              await spokenStore.addDeduplicated(spoken("s1", said: "skip")))
        check("saying it differently is still the same command",
              await !spokenStore.addDeduplicated(spoken("s2", said: "click skip")))
        check("and again",
              await !spokenStore.addDeduplicated(spoken("s3", said: "press the skip button")))
        check("only one card exists", await spokenStore.getAllPending().count == 1)
        return failures
    }

    /// An unknown app must reach the human, not be answered or discarded.
    private static func testStrictDefaultPolicyEscalatesUnknownApp() -> [String] {
        var failures: [String] = []
        let policy = Policy.strictDefault()

        let unknownApp = ApplicationInfo(name: "Unknown App", bundleIdentifier: "com.unknown.app")
        let request = ApprovalRequest(
            id: "test-1",
            kind: .appDialog,
            title: "Test",
            bodyText: "Test",
            options: [ApprovalOption(id: "ok", label: "OK", riskLevel: .low)],
            originatingApp: unknownApp,
            timestamp: Date()
        )

        let (decision, _) = policy.evaluate(request: request)
        if case .escalateToHuman = decision {
            // Expected: never auto-pressed, never silently dropped.
        } else {
            failures.append("Strict default policy should escalate an unknown app, got \(decision)")
        }

        return failures
    }

    private static func testDangerousButtonLabelNotAutoPressed() -> [String] {
        var failures: [String] = []
        let policy = Policy.strictDefault()

        let allowedApp = ApplicationInfo(name: "Allowed App", bundleIdentifier: "com.allowed.app")
        var allowedPolicy = Policy.strictDefault()
        allowedPolicy = Policy(
            allowedBundleIds: ["com.allowed.app"],
            allowedCommandPrefixes: [],
            dangerousButtonLabels: policy.dangerousButtonLabels,
            maxAutoApprovableRiskLevel: .low
        )

        let request = ApprovalRequest(
            id: "test-2",
            kind: .appDialog,
            title: "Test",
            bodyText: "Test",
            options: [
                ApprovalOption(id: "ok", label: "OK", riskLevel: .low),
                ApprovalOption(id: "delete", label: "Delete All", riskLevel: .low)
            ],
            originatingApp: allowedApp,
            timestamp: Date()
        )

        let (decision, _) = allowedPolicy.evaluate(request: request)
        if case .escalateToHuman = decision {
            // Expected
        } else {
            failures.append("Policy should escalate requests with dangerous button labels, got \(decision)")
        }

        return failures
    }

    private static func testReplayGuardRejectsDuplicate() -> [String] {
        var failures: [String] = []

        let now = Date()
        let nonce1 = Nonce(id: "test-nonce", timestamp: now)
        let nonce2 = Nonce(id: "test-nonce", timestamp: now)

        if !nonce1.isValid(against: nonce2) {
            // Expected: duplicate nonce should be rejected
        } else {
            failures.append("Replay guard should reject duplicate nonce")
        }

        return failures
    }

    private static func testRiskLevelOrdering() -> [String] {
        var failures: [String] = []

        if !(RiskLevel.low < RiskLevel.medium) {
            failures.append("RiskLevel: low should be less than medium")
        }
        if !(RiskLevel.medium < RiskLevel.high) {
            failures.append("RiskLevel: medium should be less than high")
        }
        if RiskLevel.high < RiskLevel.low {
            failures.append("RiskLevel: high should not be less than low")
        }

        return failures
    }

    private static func testNonceValidation() -> [String] {
        var failures: [String] = []

        let now = Date()

        // Test 1: Recent nonce should be valid against nil
        let recentNonce = Nonce(id: "test-nonce", timestamp: now)
        if !recentNonce.isValid(against: nil) {
            failures.append("Recent nonce should be valid when there is no previous nonce")
        }

        // Test 2: Old nonce (outside replay window) should be invalid
        let oldDate = Date(timeIntervalSince1970: now.timeIntervalSince1970 - 60) // 60 seconds ago
        let oldNonce = Nonce(id: "old-nonce", timestamp: oldDate)
        if oldNonce.isValid(against: nil) {
            failures.append("Nonce older than replay window should be invalid")
        }

        // Test 3: Recent nonce with different id should be valid against previous nonce
        let previousNonce = Nonce(id: "different-nonce", timestamp: now)
        let newNonce = Nonce(id: "another-nonce", timestamp: now)
        if !newNonce.isValid(against: previousNonce) {
            failures.append("Different nonce should be valid against previous nonce")
        }

        return failures
    }

    private static func testPolicyCommandPrefix() -> [String] {
        var failures: [String] = []

        let policy = Policy(
            allowedBundleIds: [],
            allowedCommandPrefixes: ["/bin/echo"],
            dangerousButtonLabels: [],
            maxAutoApprovableRiskLevel: .high
        )

        if policy.allowedCommandPrefixes.contains("/bin/echo") {
            // Expected
        } else {
            failures.append("Policy should preserve allowed command prefixes")
        }

        return failures
    }
}
