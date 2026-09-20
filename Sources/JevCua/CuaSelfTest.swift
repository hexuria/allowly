import Foundation
import CoreGraphics

/// Asserts that target matching refuses when it should.
///
/// This is the safety-critical half of the Cua backend and it runs offline, so
/// it is checked on every start like the vocabulary is. The property that
/// matters is not "does it find the button" — it is **"does it decline when
/// two buttons could plausibly be the one you meant"**. A resolver that
/// guesses between "Approve Invoice" and "Discard Invoice" is worse than one
/// that gives up, because you are in another room and cannot see what it did.
public enum CuaSelfTest {

    private static func element(_ label: String, _ role: String = "AXButton",
                                enabled: Bool = true, index: Int = 0,
                                frame: CGRect? = nil) -> CuaBackend.Element {
        CuaBackend.Element(index: index, role: role, label: label,
                           value: nil, token: "s1:\(index)", enabled: enabled,
                           frame: frame)
    }

    public static func run() -> [String] {
        var failures: [String] = []

        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append("cua: \(name)") }
        }

        let invoice = [
            element("Approve Invoice", index: 0),
            element("Discard Invoice", index: 1),
            element("Send Report", index: 2),
            element("Recipient email", "AXTextField", index: 3),
            element("Passphrase", "AXSecureTextField", index: 4),
        ]
        let clickable = CuaBackend.clickableRoles
        let fields = CuaBackend.fieldRoles

        // Exact label wins outright.
        check("exact match",
              CuaBackend.bestMatch(for: "Send Report", in: invoice, roles: clickable)?.label == "Send Report")

        // Case and curly apostrophes are noise, not meaning.
        check("case-insensitive",
              CuaBackend.bestMatch(for: "send report", in: invoice, roles: clickable)?.label == "Send Report")
        check("curly apostrophe folds",
              CuaBackend.bestMatch(for: "Don\u{2019}t Save",
                                   in: [element("Don't Save")], roles: clickable)?.label == "Don't Save")

        // THE one that matters: two candidates, so refuse.
        check("ambiguous refuses",
              CuaBackend.bestMatch(for: "Invoice", in: invoice, roles: clickable) == nil)

        // The ellipsis folds on THIS side too. The dialog matcher has
        // asserted this since it was written; the driver matcher did
        // not, which is why the two drifted apart and the same string
        // resolved through one path and refused through the other.
        // A menu item titled "Save As…" is the common case here.
        check("an ellipsis matches three dots",
              CuaBackend.bestMatch(for: "Save As...",
                                   in: [element("Save As\u{2026}"), element("Cancel")],
                                   roles: clickable)?.label == "Save As\u{2026}")

        // A refused FILL names the boxes, not the buttons. The two role
        // sets are disjoint, so suggesting clickable things on a fill
        // could never include the one word the person needed.
        let loginForm = [
            element("Sign in", index: 0),
            element("Email", "AXTextField", index: 1),
            element("Password", "AXSecureTextField", index: 2),
        ]
        let fillRefusal = CuaBackend.notFound("username", in: loginForm,
                                              app: "Chrome", roles: fields)
        check("a refused fill suggests fields",
              fillRefusal.contains("Email") && !fillRefusal.contains("Sign in"))
        check("a refused click still suggests buttons",
              CuaBackend.notFound("Publish", in: loginForm, app: "Chrome").contains("Sign in"))

        // A tell has to be a WORD, not a run of letters inside one.
        // "Shipping address" contains "pin", so it was masked on the
        // phone and refused by voice with "never say it out loud" —
        // over-marking is safe and it is still wrong. "typing" too.
        check("shipping is not a PIN field",
              !CuaBackend.looksSecret(element("Shipping address", "AXTextField")))
        check("typing is not a PIN field",
              !CuaBackend.looksSecret(element("Typing speed", "AXTextField")))
        // The ordinary words the widened rule must still leave alone.
        for ordinary in ["Shipping address", "Typing speed", "Full name", "Email",
                         "Street address", "Company", "Zip code", "Phone number",
                         "Search", "Notes", "Subject", "Message"] {
            if CuaBackend.looksSecret(element(ordinary, "AXTextField")) {
                failures.append("cua: “\(ordinary)” is not a secret field")
            }
        }
        // …without weakening any of the real ones, including the two
        // shapes the word-boundary rule cannot tokenise.
        for secret in ["PIN", "Enter your PIN", "Password", "One-time code",
                       "密码", "Card number", "CVV", "Social security number",
                       // Inflected and compounded, which exact-token
                       // matching quietly stopped recognising — the
                       // dangerous direction for this function.
                       "Passwords", "Salasanasi", "Wachtwoordbevestiging",
                       "userPassword", "Pincode",
                       // camelCase with a SHORT tell, which a
                       // begins-the-token rule could never see.
                       "accessToken", "userPin", "cardCvv", "smsOtp", "minhaSenha",
                       // camelCase with a multi-word tell.
                       "securityCode", "apiKey", "cardNumber", "seedPhrase",
                       // …and punctuation between the words of one.
                       "Mot-de-passe", "mot_de_passe", "api-key", "pass-code",
                       // Acronym spellings the first splitter destroyed:
                       // it turned "2FA" into "2 fa" and lost the only
                       // digit-initial tell in the list.
                       "2FA code", "2FA", "Enter 2FA code", "APIKey", "OTPCode",
                       // All-caps runs, which have no boundary to find.
                       "APIKEY", "CARDNUMBER",
                       // …and the ones round twenty-one measured as
                       // reaching the phone as plain text boxes.
                       "Recovery phrase", "Backup code", "SMS code", "TOTP",
                       "Authenticator code", "Master key", "Passwd",
                       // The splitter cuts THROUGH these, so only the
                       // de-spaced form can find them — and "PassWord"
                       // used to match before the splitter existed.
                       "PassWord", "passWord", "Pass Word", "passPhrase",
                       // Labels real sites actually use.
                       "Authentication code", "Two-factor code", "Login code",
                       "Security question", "Memorable word"] {
            if !CuaBackend.looksSecret(element(secret, "AXTextField")) {
                failures.append("cua: “\(secret)” is no longer treated as secret")
            }
        }

        // Four buttons with the same name is an ambiguity at the EXACT
        // tier too. `first(where:)` pressed whichever the driver listed
        // first — on Chrome's profile picker, which this file's own
        // comments use as the example of why numbers exist.
        let picker = [element("Alex", index: 0), element("Alex", index: 1),
                      element("Alex", index: 2)]
        check("identical exact labels refuse",
              CuaBackend.bestMatch(for: "Alex", in: picker, roles: clickable) == nil)

        // …and "several" is a DIFFERENT refusal from "none". One message
        // served both, so three buttons called "Follow" produced
        // "Nothing called “Follow” … I can see: … “Follow”" — a sentence
        // that denies what it then lists, whose implied advice (say a
        // different word) is the one thing that cannot help, because the
        // word was right and the count was the problem.
        switch CuaBackend.match(for: "Alex", in: picker, roles: clickable) {
        case .ambiguous(let tied):
            check("identical labels report as ambiguous, with the count", tied.count == 3)
        default:
            check("identical labels report as ambiguous", false)
        }

        // The count is of CONTROLS, not of accessibility packaging.
        //
        // macOS gives a button and its own label the same name, and
        // `clickableRoles` includes the wrappers on purpose so a list
        // item can be clicked at all. Counting both told the person
        // there were six Follow buttons when there were three, and
        // "number two" then resolved to the static text inside button
        // one — the wrong control, clicked, reported as success.
        let feedRows = [
            element("Follow", index: 0, frame: CGRect(x: 600, y: 100, width: 80, height: 30)),
            element("Follow", "AXStaticText", index: 1,
                    frame: CGRect(x: 604, y: 104, width: 40, height: 20)),
            element("Follow", index: 2, frame: CGRect(x: 600, y: 300, width: 80, height: 30)),
            element("Follow", "AXStaticText", index: 3,
                    frame: CGRect(x: 604, y: 304, width: 40, height: 20)),
        ]
        // A row and the switch inside it share a name and are NOT
        // interchangeable. This must stay a dead end: an earlier round
        // made `collapseWrappers` refuse it precisely so "click Safari"
        // in Privacy settings cannot flip a permission, and offering
        // "say number two" hands over that toggle in one more word,
        // with no way for the person to know which is which.
        let privacyRow = [element("Safari", "AXRow", index: 0,
                                  frame: CGRect(x: 0, y: 100, width: 400, height: 30)),
                          element("Safari", "AXCheckBox", index: 1,
                                  frame: CGRect(x: 360, y: 104, width: 30, height: 20))]
        switch CuaBackend.match(for: "Safari", in: privacyRow, roles: clickable) {
        case .tangled:
            check("a row and its switch are a dead end, not a numbered choice", true)
        default:
            check("a row and its switch are a dead end, not a numbered choice", false)
        }
        // …and the sentence must not be one that arms an ordinal.
        let tangledSentence = CuaBackend.tangled("Safari", candidates: privacyRow,
                                                 app: "System Settings")
        check("the tangled sentence offers no ordinal",
              !tangledSentence.contains("number two"))
        check("…and nothing reads a count out of it",
              CuaBackend.ambiguityCount(in: tangledSentence) == nil)

        // Every shape that must stay a dead end, including the one that
        // slipped through "two or more of one role": a row with TWO
        // switches of the same name. That offered a numbered choice
        // between two permission toggles and dropped the row — the only
        // harmless target — out of the candidate list entirely.
        let twoSwitches = [element("Safari", "AXRow", index: 0),
                           element("Safari", "AXCheckBox", index: 1),
                           element("Safari", "AXCheckBox", index: 2)]
        switch CuaBackend.match(for: "Safari", in: twoSwitches, roles: clickable) {
        case .tangled: check("a row with two switches of one name is a dead end", true)
        default:       check("a row with two switches of one name is a dead end", false)
        }
        // …and switches with no row at all.
        for role in ["AXCheckBox", "AXRadioButton", "AXDisclosureTriangle"] {
            let pair = [element("Safari", role, index: 0), element("Safari", role, index: 1)]
            switch CuaBackend.match(for: "Safari", in: pair, roles: clickable) {
            case .tangled: check("two \(role)s of one name are a dead end", true)
            default:       check("two \(role)s of one name are a dead end", false)
            }
        }
        // A toggle inside a CONTAINER is a rival target: you can select
        // the row, or you can flip the switch, and jev must not choose.
        // A SwiftUI list reports that container as AXCell, so testing
        // for AXRow alone let the switch be clicked silently.
        for wrapper in ["AXRow", "AXCell"] {
            let wrapped = [element("Safari", wrapper, index: 0),
                           element("Safari", "AXCheckBox", index: 1)]
            if case .one = CuaBackend.match(for: "Safari", in: wrapped, roles: clickable) {
                check("a switch inside an \(wrapper) is not clicked silently", false)
            } else {
                check("a switch inside an \(wrapper) is not clicked silently", true)
            }
        }

        // …but a CAPTION is not a rival, it is the switch's own name,
        // and collapsing it is this function's whole job. Widening the
        // guard to every wrapper role broke the commonest form control
        // there is — `<label>Dark Mode</label><input type=checkbox>`
        // reports AXStaticText + AXCheckBox — so "click dark mode"
        // stopped working on ordinary settings pages.
        for caption in ["AXStaticText", "AXImage"] {
            let labelled = [element("Dark Mode", caption, index: 0),
                            element("Dark Mode", "AXCheckBox", index: 1)]
            if case .one(let only) = CuaBackend.match(for: "Dark Mode", in: labelled,
                                                      roles: clickable) {
                check("a labelled switch (\(caption)) still resolves",
                      only.role == "AXCheckBox")
            } else {
                check("a labelled switch (\(caption)) still resolves", false)
            }
        }

        // …while the genuinely interchangeable case IS answerable. Two
        // identical rows in a list are the same kind of thing separated
        // only by position, which is what an ordinal expresses.
        let twoRows = [element("Inbox", "AXRow", index: 0,
                               frame: CGRect(x: 0, y: 100, width: 300, height: 24)),
                       element("Inbox", "AXRow", index: 1,
                               frame: CGRect(x: 0, y: 140, width: 300, height: 24))]
        switch CuaBackend.match(for: "Inbox", in: twoRows, roles: clickable) {
        case .ambiguous(let rows): check("two identical rows can be numbered", rows.count == 2)
        default:                   check("two identical rows can be numbered", false)
        }

        // The count must mean what the person can see. A disabled,
        // frameless or hairline candidate is not something they can
        // pick, and counting it made "number two" reach a control they
        // never saw — a frameless one sorted to position ONE, because
        // its order key is zero.
        let unreachable = [
            element("Follow", index: 0, frame: CGRect(x: 600, y: 100, width: 80, height: 30)),
            element("Follow", enabled: false, index: 1,
                    frame: CGRect(x: 600, y: 200, width: 80, height: 30)),
            element("Follow", index: 2, frame: nil),
            element("Follow", index: 3, frame: CGRect(x: 600, y: 300, width: 4, height: 4)),
        ]
        // Exactly one you could press is not an ambiguity — it is the
        // answer. Refusing here printed "is a Button, and I cannot tell
        // which you mean" about a page showing ONE Follow, which is the
        // same self-denying sentence this whole change set out to
        // delete.
        switch CuaBackend.match(for: "Follow", in: unreachable, roles: clickable) {
        case .one(let only):
            check("one reachable candidate resolves rather than refusing",
                  only.index == 0)
        default:
            check("one reachable candidate resolves rather than refusing", false)
        }
        // …but when the driver reports no frames at all, geometry
        // cannot be the filter, or the feature disappears.
        switch CuaBackend.match(for: "Alex",
                                in: [element("Alex", index: 0), element("Alex", index: 1)],
                                roles: clickable) {
        case .ambiguous(let tied): check("frameless candidates still count", tied.count == 2)
        default:                   check("frameless candidates still count", false)
        }

        // Mixed real controls are the same dead end — and the safe one
        // must not be silently dropped from the choice.
        let mixed = [element("Safari", "AXRow", index: 0),
                     element("Safari", "AXCheckBox", index: 1),
                     element("Safari", "AXPopUpButton", index: 2)]
        switch CuaBackend.match(for: "Safari", in: mixed, roles: clickable) {
        case .tangled: check("two different kinds of control are a dead end", true)
        default:       check("two different kinds of control are a dead end", false)
        }

        switch CuaBackend.match(for: "Follow", in: feedRows, roles: clickable) {
        case .ambiguous(let tied):
            check("wrappers do not inflate the count", tied.count == 2)
            check("…and the candidates are the real controls",
                  tied.allSatisfy { $0.role == "AXButton" })
        default:
            check("two buttons plus their labels report as ambiguous", false)
        }
        switch CuaBackend.match(for: "Nonesuch", in: picker, roles: clickable) {
        case .none: check("a name that is not there reports as absent", true)
        default:    check("a name that is not there reports as absent", false)
        }
        switch CuaBackend.match(for: "Ada", in: [element("Alex"), element("Ada")],
                                roles: clickable) {
        case .one(let only): check("a single match still resolves", only.label == "Ada")
        default:             check("a single match still resolves", false)
        }
        // Reading order decides what "number two" means, and it has to
        // be the SAME order the badges are drawn in, or the number the
        // person reads picks a different button than the one under it.
        let feed = [
            element("Follow", index: 0, frame: CGRect(x: 600, y: 300, width: 80, height: 30)),
            element("Follow", index: 1, frame: CGRect(x: 600, y: 100, width: 80, height: 30)),
            element("Follow", index: 2, frame: CGRect(x: 600, y: 200, width: 80, height: 30)),
        ]
        let ordered = feed.sorted(by: CuaBackend.readingOrder)
        check("reading order is top to bottom, whatever order the driver reported",
              ordered.map(\.index) == [1, 2, 0])
        let sameRow = [
            element("Follow", index: 0, frame: CGRect(x: 600, y: 100, width: 80, height: 30)),
            element("Follow", index: 1, frame: CGRect(x: 200, y: 104, width: 80, height: 30)),
        ]
        check("…and left to right within a row, despite a few pixels of drift",
              sameRow.sorted(by: CuaBackend.readingOrder).map(\.index) == [1, 0])

        // The refusal a person reads carries NOTHING but words.
        //
        // The window was briefly appended to it after an invisible
        // separator — but only the separator is invisible, so "w4211"
        // rendered on the phone's toast, in the approval card and in
        // commands.jsonl. A sentence shown to a person is not a
        // transport; the window lives beside the matcher now.
        let sentence = CuaBackend.ambiguous("Follow", count: 3, app: "Chrome")
        check("the refusal is only words",
              sentence.allSatisfy { !$0.unicodeScalars.contains { s in
                  s.properties.generalCategory == .format } })
        check("…and it still ends with the advice",
              sentence.hasSuffix("say which one, like \u{201C}number two\u{201D}"))

        let tiedSentence = CuaBackend.ambiguous("Follow", count: 3, app: "Chrome")
        check("the ambiguous sentence gives the count",
              tiedSentence.contains("3 things called"))
        check("…and points at the one thing that resolves it",
              tiedSentence.contains("number two"))
        // The reader and the writer of that sentence must agree, because
        // the runtime learns "there were three" by reading it back.
        check("the count can be read back out of the sentence",
              CuaBackend.ambiguityCount(in: tiedSentence) == 3)
        check("…and an ordinary refusal is not mistaken for one",
              CuaBackend.ambiguityCount(
                in: CuaBackend.notFound("Refund", in: [], app: "Chrome")) == nil)
        check("…and never claims the thing is absent",
              !tiedSentence.lowercased().contains("nothing called"))

        // …but a row, its cell and its text are ONE thing wearing three
        // accessibility wrappers, and macOS names all three the same as
        // a matter of course. Counting them as rivals refused "click
        // General" in System Settings with "I can see: General, General"
        // — worse than the guess it replaced.
        let sidebarRow = [
            element("General", "AXRow", index: 0),
            element("General", "AXCell", index: 1),
            element("General", "AXStaticText", index: 2),
        ]
        check("a row and its own label are not two candidates",
              CuaBackend.bestMatch(for: "General", in: sidebarRow, roles: clickable)?.role == "AXRow")
        // A real control beats its packaging outright.
        let labelledButton = [
            element("Continue", "AXStaticText", index: 0),
            element("Continue", "AXButton", index: 1),
        ]
        check("the button wins over the text inside it",
              CuaBackend.bestMatch(for: "Continue", in: labelledButton, roles: clickable)?.role == "AXButton")
        // A switch inside a row named the same thing is NOT that row's
        // packaging. In a Privacy pane every row carries a toggle that
        // AX names after the app, so "click Safari" would have flipped
        // a permission instead of selecting the row.
        check("a toggle inside a row of the same name is ambiguous",
              CuaBackend.bestMatch(for: "Safari",
                                   in: [element("Safari", "AXRow", index: 0),
                                        element("Safari", "AXCheckBox", index: 1)],
                                   roles: clickable) == nil)

        // Collapsing is only ever WITHIN one name. In the prefix tier
        // the candidates have different labels, and "a control beats
        // its packaging" there pressed a control belonging to another
        // name — "click Delete" against a row "Delete Forever" and a
        // button "Delete Everything" pressed the destructive one.
        check("a prefix match across two names refuses",
              CuaBackend.bestMatch(for: "Delete",
                                   in: [element("Delete Forever", "AXRow", index: 0),
                                        element("Delete Everything", index: 1)],
                                   roles: clickable) == nil)
        check("…and so does a row plus a differently-named cell",
              CuaBackend.bestMatch(for: "Photo",
                                   in: [element("Photos", "AXRow", index: 0),
                                        element("Photo Booth", "AXCell", index: 1)],
                                   roles: clickable) == nil)
        // One name wearing three wrappers still resolves in the prefix
        // tier, which is what the collapse is for.
        check("one name in three wrappers still resolves by prefix",
              CuaBackend.bestMatch(for: "Sound",
                                   in: [element("Sound & Haptics", "AXRow", index: 0),
                                        element("Sound & Haptics", "AXCell", index: 1),
                                        element("Sound & Haptics", "AXStaticText", index: 2)],
                                   roles: clickable)?.role == "AXRow")

        // Two real controls with one name is still an ambiguity.
        check("two buttons of the same name still refuse",
              CuaBackend.bestMatch(for: "Delete",
                                   in: [element("Delete", index: 0), element("Delete", index: 1)],
                                   roles: clickable) == nil)
        check("one exact label still resolves",
              CuaBackend.bestMatch(for: "Alex", in: [element("Alex"), element("Ada")],
                                   roles: clickable)?.label == "Alex")

        // A word that names nothing is a failure, never a nearest guess.
        check("absent refuses",
              CuaBackend.bestMatch(for: "Refund", in: invoice, roles: clickable) == nil)

        // An exact hit still wins even when another label contains it, because
        // "Save" must never resolve to "Don't Save".
        let saves = [element("Save"), element("Don't Save"), element("Save As…")]
        check("exact beats containment",
              CuaBackend.bestMatch(for: "Save", in: saves, roles: clickable)?.label == "Save")

        // Roles are honoured: a text field is not clickable, a button is not fillable.
        check("field roles separate",
              CuaBackend.bestMatch(for: "Recipient email", in: invoice, roles: clickable) == nil)
        check("field found by field role",
              CuaBackend.bestMatch(for: "Recipient email", in: invoice, roles: fields)?.label == "Recipient email")
        check("button not fillable",
              CuaBackend.bestMatch(for: "Send Report", in: invoice, roles: fields) == nil)

        // An unlabelled control is kept for numbering, but must never be
        // matched by name — an empty label would otherwise swallow anything.
        let unnamed = [element("", index: 9), element("Save", index: 10)]
        check("unlabelled never matches by name",
              CuaBackend.bestMatch(for: "", in: unnamed, roles: clickable) == nil)
        check("named still wins beside an unlabelled one",
              CuaBackend.bestMatch(for: "Save", in: unnamed, roles: clickable)?.index == 10)

        // Empty input never matches anything.
        check("empty refuses", CuaBackend.bestMatch(for: "   ", in: invoice, roles: clickable) == nil)

        // Addressing prefers the snapshot token, which goes stale safely;
        // a bare index can silently point at a different control after a redraw.
        var args: [String: Any] = [:]
        CuaBackend.address(element("Save", index: 7), into: &args)
        check("addresses by token", args["element_token"] as? String == "s1:7" && args["element_index"] == nil)
        var indexed: [String: Any] = [:]
        CuaBackend.address(CuaBackend.Element(index: 3, role: "AXButton", label: "Save",
                                              value: nil, token: nil, enabled: true), into: &indexed)
        check("falls back to index", indexed["element_index"] as? Int == 3)

        // Secrets. Chrome gives a web password box the plain AXTextField
        // role, so role alone is not enough — under-marking one means it can
        // be dictated aloud.
        check("native secure role is secret",
              CuaBackend.looksSecret(element("Anything", "AXSecureTextField")))
        for label in ["Password", "Passphrase", "Confirm password", "Card CVV",
                      "One-time code", "API key", "PIN"] {
            check("secret by label: \(label)",
                  CuaBackend.looksSecret(element(label, "AXTextField")))
        }
        for label in ["Recipient email", "Full name", "Search", "Message"] {
            check("not secret: \(label)",
                  !CuaBackend.looksSecret(element(label, "AXTextField")))
        }
        // A Mac is not always in English. Each of these is a real sign-in
        // label; missing one puts a password on the phone as a dictatable box.
        for label in ["Contraseña", "Mot de passe", "Passwort", "Wachtwoord",
                      "パスワード", "密码", "비밀번호", "Пароль", "Hasło", "Şifre"] {
            check("secret in another language: \(label)",
                  CuaBackend.looksSecret(element(label, "AXTextField")))
        }

        // Frames are parsed from either spelling the driver uses.
        check("frame parses w/h",
              CuaBackend.rect(["x": 10.0, "y": 20.0, "w": 30.0, "h": 40.0])
                == CGRect(x: 10, y: 20, width: 30, height: 40))
        check("frame parses width/height",
              CuaBackend.rect(["x": 10, "y": 20, "width": 30, "height": 40])
                == CGRect(x: 10, y: 20, width: 30, height: 40))
        check("frame rejects rubbish", CuaBackend.rect(["x": 1.0]) == nil)

        // The wire format. Both halves of this were wrong at once and the
        // result was silent: every call succeeded and nothing happened.
        let body = CuaDriver.requestBody(tool: "click", arguments: ["pid": 42])
        check("request uses args, not arguments", body["args"] != nil && body["arguments"] == nil)
        check("request carries the tool name", body["name"] as? String == "click")
        check("arguments actually travel",
              ((body["args"] as? [String: Any])?["pid"] as? Int) == 42)

        // A tool can refuse inside a successful envelope.
        check("isError is a failure",
              CuaDriver.isToolError(["isError": true, "content": [["text": "Missing required integer field: pid"]]]))
        check("plain result is not a failure", !CuaDriver.isToolError(["structuredContent": [:]]))
        check("refusal text is surfaced",
              CuaDriver.toolMessage(["content": [["text": "Missing required integer field: pid"]]])?
                .contains("Missing required") == true)

        // A lapsed session arrives by two routes and both must trigger the
        // retry; matching only the code left every call dead until restart.
        check("session_ended code detected",
              CuaDriver.isSessionEnded("session_ended: this session has ended"))
        check("session_ended prose detected",
              CuaDriver.isSessionEnded("this session has ended; call start_session explicitly"))
        check("ordinary refusals are not session_ended",
              !CuaDriver.isSessionEnded("Missing required integer field: pid"))

        // ── The geometry contract ───────────────────────────────────────
        //
        // Every one of these encodes a bug that shipped. They run offline,
        // at every start, because the failures they describe are invisible
        // on a single non-Retina display and obvious on a real desk.
        let retina = Geometry.Shown(width: 1800, height: 1169, scale: 2)

        // The factor of two. A tap meant for the middle landed a quarter in.
        let middle = Geometry.pixels(Geometry.Normalised(x: 0.5, y: 0.5), on: retina)
        check("centre tap is in pixels, not points",
              middle?.x == 1800 && middle?.y == 1169)
        let corner = Geometry.pixels(Geometry.Normalised(x: 1, y: 1), on: retina)
        check("bottom-right reaches the far pixel",
              corner?.x == 3600 && corner?.y == 2338)

        // Off-screen input is clamped, never wrapped to the far side.
        let under = Geometry.pixels(Geometry.Normalised(x: -0.5, y: 2), on: retina)
        check("out of range clamps", under?.x == 0 && under?.y == 2338)

        // Points to pixels, on its own.
        let p = Geometry.pixels(Geometry.Points(x: 100, y: 50), on: retina)
        check("points scale to pixels", p?.x == 200 && p?.y == 100)

        // A display that reported nonsense produces NO coordinate at all.
        //
        // This is not fussiness. `Shown` turns a bogus scale into NaN, and a
        // NaN in a JSON request raises an Objective-C exception that Swift
        // cannot catch — the daemon dies, mid-click, with no log line. A
        // locked or waking display has reported scale 0.
        let broken = Geometry.Shown(width: 1800, height: 1169, scale: 0)
        check("a bogus scale is not usable", !broken.isUsable)
        check("no pixels from an unusable display",
              Geometry.pixels(Geometry.Normalised(x: 0.5, y: 0.5), on: broken) == nil)
        check("no pixels from unusable points",
              Geometry.pixels(Geometry.Points(x: 100, y: 50), on: broken) == nil)
        check("a NaN fraction produces no coordinate",
              Geometry.pixels(Geometry.Normalised(x: .nan, y: 0.5), on: retina) == nil)

        // An unlabelled box's ADDRESS cannot collide with a real label.
        //
        // Two attempts at this shipped wrong. Sending the caption back put
        // it through `bestMatch`, whose prefix and containment tiers then
        // matched a real box called "Field 10" or "Field 1 (optional)" —
        // a value typed into box 1 written silently into box 10.
        check("an address is not a name a form could use",
              CuaBackend.placeholderOrdinal("Field 1") == nil
                && CuaBackend.placeholderOrdinal("Unnamed box 1") == nil
                && CuaBackend.placeholderOrdinal("Field 1 (optional)") == nil
                && CuaBackend.placeholderOrdinal("Custom Field 1") == nil)
        let first = CuaBackend.placeholderOrdinal(CuaBackend.positionalAddress(1, of: 4, inWindow: 77))
        let last = CuaBackend.placeholderOrdinal(CuaBackend.positionalAddress(12, of: 12, inWindow: 9))
        check("an address round-trips to its position",
              first?.ordinal == 1 && last?.ordinal == 12)
        // The shape it was counted in travels with it, so a form that
        // gained or lost a box while you typed is refused rather than
        // filled one row out.
        check("an address carries the shape it was counted in",
              first?.of == 4 && last?.of == 12)
        // And the WINDOW, because a two-field login page and a two-field
        // search box have the same shape. Focus moving between them once
        // typed a password into the wrong app and called it success.
        check("an address names the window it was counted in",
              first?.window == 77 && last?.window == 9)
        check("half an address is not an address",
              CuaBackend.placeholderOrdinal("jev:box:3") == nil
                && CuaBackend.placeholderOrdinal("jev:box:") == nil
                && CuaBackend.placeholderOrdinal("jev:box:a/b") == nil
                && CuaBackend.placeholderOrdinal("jev:box:1/3") == nil
                && CuaBackend.placeholderOrdinal("jev:box:1/3@x") == nil)
        // The two captions stay distinct, so a card never shows one name twice.
        check("the two captions differ",
              CuaBackend.placeholderName(2) != CuaBackend.fallbackName(2))
        // Neither caption is ever mistaken for an address.
        check("a caption is never an address",
              CuaBackend.placeholderOrdinal(CuaBackend.placeholderName(2)) == nil
                && CuaBackend.placeholderOrdinal(CuaBackend.fallbackName(2)) == nil)

        // A control on this display normalises; one on the next does not,
        // and says so instead of producing a negative coordinate.
        let here = Geometry.normalised(CGRect(x: 900, y: 584, width: 90, height: 58), on: retina)
        check("on-display control normalises", here != nil && abs((here!.x) - 0.5) < 0.001)
        let elsewhere = Geometry.normalised(CGRect(x: 1900, y: 1200, width: 90, height: 58), on: retina)
        check("second-display control has no place here", elsewhere == nil)
        let above = Geometry.normalised(CGRect(x: 100, y: -40, width: 90, height: 20), on: retina)
        check("a control above the top is refused, not negative", above == nil)

        // Choosing a window: the centre decides, not a shared edge.
        let hairline = CGRect(x: 1799, y: 1137, width: 900, height: 1129)
        check("a one-pixel overlap is not this display",
              !Geometry.isCentredOnShownDisplay(hairline, retina))
        check("a window you are looking at is",
              Geometry.isCentredOnShownDisplay(CGRect(x: 0, y: 39, width: 1800, height: 1129), retina))

        // A zero-size display must not divide by zero or claim anything.
        let dead = Geometry.Shown(width: 0, height: 0, scale: 2)
        check("no display means no answer",
              Geometry.normalised(Geometry.Points(x: 10, y: 10), on: dead) == nil)
        check("nothing is on a display that is not there",
              !Geometry.isOnShownDisplay(CGRect(x: 0, y: 0, width: 10, height: 10), dead))

        // Pressability is a property of the fraction, not of the caller.
        check("inside is pressable", Geometry.Normalised(x: 0.4, y: 0.4).isOnScreen)
        check("parked off is not", !Geometry.Normalised(x: 1.12, y: 0.5).isOnScreen)

        // The three ways nothing happens must read differently. They were
        // one sentence before, and two thirds of the time it was untrue.
        let cannot = CuaBackend.Refusal.cannotSee("the driver is not answering").description
        let otherScreen = CuaBackend.Refusal.notOnThisScreen("Google Chrome").description
        let empty = CuaBackend.Refusal.nothingThere("Nothing fillable here").description
        check("cannot-see says so", cannot.contains("Cannot see the screen"))
        check("other display says so", otherScreen.contains("other display"))
        check("other display names the app", otherScreen.contains("Google Chrome"))
        check("nothing-there is its own words", empty == "Nothing fillable here")
        check("the three read differently",
              Set([cannot, otherScreen, empty]).count == 3)

        // ── Window selection: the policy, not just its parts ────────────
        //
        // This is the assertion that was missing. The old code computed the
        // right answer and then discarded it with a fallback, and all fifty
        // other assertions passed while jev clicked in a window on the other
        // monitor.
        func win(_ id: Int, _ z: Int, _ x: Double, _ y: Double,
                 _ w: Double = 900, _ h: Double = 600) -> [String: Any] {
            ["window_id": id, "z_index": z,
             "bounds": ["x": x, "y": y, "width": w, "height": h]]
        }
        let visibleWindow = win(1, 120, 0, 39)    // on the shown display
        let otherScreenWindow = win(2, 113, 1799, 1137)  // one pixel of overlap

        check("the visible window wins even when further back",
              (CuaBackend.chooseWindow([otherScreenWindow, visibleWindow], on: retina)?["window_id"] as? Int) == 1)
        check("no fallback to the other display",
              CuaBackend.chooseWindow([otherScreenWindow], on: retina) == nil)
        check("nothing at all is nothing",
              CuaBackend.chooseWindow([], on: retina) == nil)
        check("frontmost of two visible windows wins",
              (CuaBackend.chooseWindow([win(3, 200, 10, 10), win(4, 50, 20, 20)], on: retina)?["window_id"] as? Int) == 4)
        check("a zero-size window is never chosen",
              CuaBackend.chooseWindow([win(5, 10, 100, 100, 0, 0)], on: retina) == nil)

        // A control half off the right edge is still visible and must keep
        // its number — full containment silently dropped it and reported an
        // empty screen.
        let halfOff = Geometry.normalised(CGRect(x: 1750, y: 100, width: 80, height: 30), on: retina)
        check("a control overhanging the edge keeps its number", halfOff != nil)
        check("and its fraction is never negative",
              halfOff == nil || (halfOff!.x >= 0 && halfOff!.y >= 0))
        // A badge is drawn at the centre of what comes back, so what comes
        // back must be the VISIBLE part. Clamping the origin alone left the
        // full width behind and put the badge 10 points off.
        func badgeCentre(_ r: CGRect) -> Double? {
            guard let b = Geometry.normalised(r, on: retina) else { return nil }
            return (b.x + b.w / 2) * retina.width
        }
        check("left overhang: badge sits on the visible half",
              badgeCentre(CGRect(x: -20, y: 100, width: 80, height: 30)).map { abs($0 - 30) < 0.5 } == true)
        check("right overhang: badge sits on the visible half",
              badgeCentre(CGRect(x: 1750, y: 100, width: 80, height: 30)).map { abs($0 - 1775) < 0.5 } == true)
        check("no overhang: badge sits in the middle",
              badgeCentre(CGRect(x: 100, y: 100, width: 80, height: 30)).map { abs($0 - 140) < 0.5 } == true)
        let hangingLeft = Geometry.normalised(CGRect(x: -20, y: 100, width: 80, height: 30), on: retina)
        check("overhanging the left edge starts at zero",
              hangingLeft != nil && hangingLeft!.x == 0)
        check("and its width is never negative or zero",
              hangingLeft != nil && hangingLeft!.w > 0)
        check("a zero-size control has no box",
              Geometry.normalised(CGRect(x: 100, y: 100, width: 0, height: 0), on: retina) == nil)

        // A bogus scale must make the display unusable, not quietly become 1.
        check("scale 0 is not a display", !Geometry.Shown(width: 1800, height: 1169, scale: 0).isUsable)
        check("NaN scale is not a display",
              !Geometry.Shown(width: 1800, height: 1169, scale: .nan).isUsable)
        check("a real scale is fine", Geometry.Shown(width: 1800, height: 1169, scale: 2).isUsable)
        check("an unusable display normalises nothing",
              Geometry.normalised(CGRect(x: 10, y: 10, width: 10, height: 10),
                                  on: Geometry.Shown(width: 1800, height: 1169, scale: 0)) == nil)

        // Refusals get turned into something a person can act on.
        check("off-space explained",
              CuaBackend.humanise("ax_window_unresolved: window_id 1 exists").contains("another Space"))

        // What is under the pointer: the innermost scope. The smallest
        // containing frame wins, because a button sits inside a toolbar sits
        // inside a window and all three contain the point.
        let placed: [(label: String, frame: CGRect)] = [
            ("Window", CGRect(x: 0, y: 0, width: 1000, height: 800)),
            ("Toolbar", CGRect(x: 0, y: 0, width: 1000, height: 60)),
            ("Save", CGRect(x: 900, y: 10, width: 80, height: 40)),
            ("", CGRect(x: 900, y: 10, width: 80, height: 40)),
        ]
        func pointed(_ name: String, _ p: CGPoint, _ expected: String?) {
            if CuaBackend.labelUnder(point: p, in: placed) != expected {
                failures.append("pointer: \(name)")
            }
        }
        pointed("the button, not the toolbar it sits in", CGPoint(x: 920, y: 30), "Save")
        pointed("the toolbar where there is no button", CGPoint(x: 100, y: 30), "Toolbar")
        pointed("the window body", CGPoint(x: 500, y: 400), "Window")
        pointed("outside everything is nothing", CGPoint(x: 2000, y: 2000), nil)
        pointed("an unlabelled control never wins", CGPoint(x: 920, y: 30), "Save")

        // The window under a point, from list_windows. Frontmost wins among
        // those containing it; off-screen and other-Space windows never do.
        let windows: [[String: Any]] = [
            ["pid": 1, "window_id": 10, "z_index": 3, "is_on_screen": true,
             "bounds": ["x": 0, "y": 0, "width": 2000, "height": 1200]],           // Chrome, behind
            ["pid": 2, "window_id": 20, "z_index": 1, "is_on_screen": true,
             "bounds": ["x": 100, "y": 100, "width": 800, "height": 600]],         // Waz, in front
            ["pid": 3, "window_id": 30, "z_index": 0, "is_on_screen": false,
             "bounds": ["x": 100, "y": 100, "width": 800, "height": 600]],         // hidden
            ["pid": 4, "window_id": 40, "z_index": 0, "on_current_space": false,
             "bounds": ["x": 100, "y": 100, "width": 800, "height": 600]],         // other Space
        ]
        func underWindow(_ name: String, _ p: CGPoint, _ pid: Int?) {
            if CuaBackend.windowUnder(point: p, in: windows)?["pid"] as? Int != pid {
                failures.append("window: \(name)")
            }
        }
        underWindow("the overlay in front, not the app behind it", CGPoint(x: 300, y: 300), 2)
        underWindow("outside the overlay, the app behind", CGPoint(x: 1500, y: 900), 1)
        underWindow("hidden and other-Space windows never win", CGPoint(x: 300, y: 300), 2)
        underWindow("nothing under a point off every window", CGPoint(x: 3000, y: 3000), nil)

        return failures
    }
}
