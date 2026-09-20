import Foundation
import JevCore

/// Asserts what the vocabulary actually resolves to.
///
/// Adding a phrase is easy; adding one that quietly steals an existing phrase
/// is just as easy, and the failure is silent — you say one thing and the Mac
/// does another. Matching is longest-first over a table with fuzzy fallback,
/// so the interactions are not obvious by reading. Every phrase below is
/// checked against the command it is supposed to produce, with a fixed
/// context so the result does not depend on what happens to be frontmost.
enum VocabularySelfTest {

    private static let finder = Phrasebook.Context(
        bundleId: "com.apple.finder", appName: "Finder", isBrowserLike: false)
    private static let youtube = Phrasebook.Context(
        bundleId: "com.google.Chrome", appName: "Google Chrome",
        isBrowserLike: true, host: "youtube.com")
    private static let plainWeb = Phrasebook.Context(
        bundleId: "com.google.Chrome", appName: "Google Chrome",
        isBrowserLike: true, host: "example.com")

    static func run() -> [String] {
        var failures: [String] = []

        // MARK: The phrasebook outranks the on-screen control gate.
        //
        // `Runtime.controlMatching` runs before `VoiceCommand.parse`, so
        // a binding whose object matches a visible label is stolen and
        // becomes a button press. Measured: "click away" means Escape,
        // and on a page with a control labelled "Away" the gate matched
        // it EXACTLY — strictness is no defence, only precedence is.
        //
        // The gate yields whenever the phrasebook claims the phrase, so
        // what has to hold is that the phrasebook really does claim
        // these. If one of them stops parsing, the gate silently starts
        // pressing buttons instead.
        // Only the phrases that are COMPLETE commands on their own.
        //
        // "select cell" is not one — its binding refuses an empty
        // argument, so the phrasebook does not run it and the gate
        // correctly no longer claims it. Asserting otherwise was
        // encoding the looser prefix-only rule that made "Print
        // Invoice" unpressable.
        for phrase in ["select all", "select everything", "click this", "click here",
                       "click it", "click away", "next field", "tab"] {
            if !Phrasebook.claimsExactly(phrase, in: finder) {
                failures.append("vocab: the phrasebook no longer claims “\(phrase)”, "
                    + "so the control gate will press a button of that name instead")
            }
        }

        // …and the other direction, which matters just as much. The gate
        // yields on an EXACT claim only, because yielding on a near
        // match handed ordinary button presses to the pointer: with a
        // Home link on screen, "click home" is within Levenshtein budget
        // of a binding. Measured, 20 of 43 common button labels were
        // taken that way. These must stay unclaimed so the button wins.
        // Punctuated transcripts are real — three neighbouring functions
        // already strip `.!?`, and `claimsExactly` did not, so one full
        // stop turned "click away." into a button press.
        for phrase in ["click away.", "select all.", "click this!", "click here?"] {
            if !Phrasebook.claimsExactly(phrase, in: finder) {
                failures.append("vocab: “\(phrase)” is not claimed once punctuated, "
                    + "so the control gate will press a button of that name")
            }
        }

        // The gate must not claim a sentence the phrasebook would then
        // decline to build. It claimed on the prefix alone, so a button
        // labelled "Print Invoice" became unpressable: the gate yielded
        // and `parse` returned nil, and nothing pressed anything.
        for phrase in ["print invoice", "save draft", "copy link", "cancel order",
                       "bold text", "tab bar", "new tab group", "mute all",
                       "click this week", "click away team"] {
            if Phrasebook.claimsExactly(phrase, in: Phrasebook.neutral),
               Phrasebook.parse(phrase, in: Phrasebook.neutral) == nil {
                failures.append("vocab: the gate claims “\(phrase)” but the phrasebook "
                    + "will not run it, so a button of that name cannot be pressed")
            }
        }

        for phrase in ["click home", "click share", "click chat", "click more",
                       "click help", "click play", "press ship", "tap hero",
                       "click follow", "click chart", "click theme"] {
            if Phrasebook.claimsExactly(phrase, in: finder) {
                failures.append("vocab: the phrasebook now claims “\(phrase)”, "
                    + "so a button of that name can no longer be pressed")
            }
        }

        // MARK: No phrase belongs to two bindings.
        //
        // The table is matched longest-first on each binding's FIRST
        // phrase, and `sorted(by:)` is not documented to be stable — so
        // a phrase claimed twice resolves to whichever binding the sort
        // happened to put first. "search notes" was claimed by both the
        // Notes binding and the generic search binding, and the winner
        // decided whether the words went into Notes or into the
        // browser's address bar.
        var seen: Set<String> = []
        for phrase in Phrasebook.allPhrases where !seen.insert(phrase).inserted {
            failures.append("vocab: “\(phrase)” is claimed by two bindings")
        }

        // MARK: One number, one meaning.
        //
        // "volume five" and "volume 5" meant different things — 50% and
        // 5% — decided by which spelling the recogniser happened to
        // emit, which is not a choice anyone made. Fixed once by keying
        // on the token's LENGTH, which can never be short for a spelled
        // digit, so the two stayed 10x apart with the values merely
        // swapped. Keyed on the value now.
        func volume(_ phrase: String) -> Int? {
            guard let parsed = Phrasebook.parse(phrase, in: finder),
                  case .systemAction(let name, let value) = parsed.command,
                  name == "volumeSet" else { return nil }
            return value
        }
        for (phrase, want) in [("volume 5", 50), ("volume five", 50), ("volume half", 50),
                               ("volume 50", 50), ("volume 100", 100), ("volume 0", 0),
                               ("volume zero", 0), ("volume 10", 100), ("volume ten", 100),
                               ("set volume to 75 percent", 75),
                               // An explicitly stated unit is not a tenth.
                               ("set volume to 5 percent", 5)] {
            if volume(phrase) != want {
                failures.append("“\(phrase)” should be \(want)%, got \(volume(phrase).map(String.init) ?? "nothing")")
            }
        }
        // Out of range is CLAMPED, not refused. Refusing dropped the
        // phrase into the fuzzy matcher, which scored "volume up"
        // against "volume -5" inside its edit budget — so asking for a
        // nonsense volume turned the volume up instead.
        for (phrase, want) in [("volume 200", 100), ("volume -5", 0), ("volume 1000", 100)] {
            if volume(phrase) != want {
                failures.append("“\(phrase)” should clamp to \(want)%, got \(volume(phrase).map(String.init) ?? "nothing")")
            }
        }

        // MARK: Pointing. "this" and "here" must never be read as a target name.
        expect("click this", in: finder, isPointer: "click", &failures)
        expect("click here", in: finder, isPointer: "click", &failures)
        expect("click it", in: finder, isPointer: "click", &failures)
        expect("tap here", in: finder, isPointer: "click", &failures)
        expect("right click this", in: finder, isPointer: "right", &failures)
        expect("right click here", in: finder, isPointer: "right", &failures)
        expect("double click this", in: finder, isPointer: "double", &failures)
        expect("open this", in: finder, isPointer: "double", &failures)

        // The pre-existing "right click <target>" must survive: "this" is a
        // position, but a named control is still a named control.
        if case .rightClickControl(let label, _, _, _)? = Phrasebook.parse("right click the submit button", in: finder)?.command {
            if !label.contains("submit") {
                failures.append("“right click the submit button” lost its target (got “\(label)”)")
            }
        } else {
            failures.append("“right click the submit button” no longer right clicks a named control")
        }

        // MARK: Typing on the phone rather than through the microphone.
        expectSecretPrompt("enter password here", in: finder, secret: true, &failures)
        expectSecretPrompt("type password", in: finder, secret: true, &failures)
        expectSecretPrompt("type here", in: finder, secret: false, &failures)
        expectSecretPrompt("write here", in: finder, secret: false, &failures)

        // "enter" on its own is still the Return key, and "type <words>" still
        // types those words. Both were one prefix away from being swallowed.
        expect("enter", in: finder, isKeys: "return", &failures)
        expect("press enter", in: finder, isKeys: "return", &failures)
        if case .sequence(_, let steps)? = Phrasebook.parse("type hello world", in: finder)?.command,
           case .typeText(let text)? = steps.first {
            if text != "hello world" { failures.append("“type hello world” typed “\(text)”") }
        } else if case .typeText(let text)? = Phrasebook.parse("type hello world", in: finder)?.command {
            if text != "hello world" { failures.append("“type hello world” typed “\(text)”") }
        } else {
            failures.append("“type hello world” no longer types")
        }

        // MARK: Scope. The same word, three different meanings.
        expect("mute", in: youtube, isKeys: "m", &failures)
        expect("mute this", in: youtube, isKeys: "m", &failures)
        expect("mute the video", in: youtube, isKeys: "m", &failures)
        expect("play", in: youtube, isKeys: "k", &failures)
        expect("mute", in: finder, isSystemAction: "mute", &failures)
        expect("mute", in: plainWeb, isSystemAction: "mute", &failures)
        // The escape hatch: explicit words always mean the Mac, even on a page
        // that redefines the bare word.
        expect("mute everything", in: youtube, isSystemAction: "mute", &failures)
        expect("mute the mac", in: youtube, isSystemAction: "mute", &failures)
        // A profile only claims what it defines; everything else falls through.
        expect("volume up", in: youtube, isSystemAction: "volumeUp", &failures)
        expect("max volume", in: youtube, isSystemAction: "volumeSet", &failures)

        // MARK: Forms. These sit right next to the "show guides" family.
        expectForm("show me the form", in: finder, &failures)
        expectForm("show form", in: finder, &failures)
        expectForm("fill the form", in: finder, &failures)
        expectForm("show the login form", in: finder, &failures)

        // MARK: A verb must not swallow the sentence after it.
        expectNoMatch("copy the link and open a new tab", in: finder, &failures)
        expectNoMatch("delete all the files in my downloads folder", in: finder, &failures)
        expectNoMatch("save the world from itself", in: finder, &failures)
        expectNoMatch("print a report of everything that happened", in: finder, &failures)
        // …while trailing politeness still works, and still costs nothing.
        expect("copy please", in: finder, isKeys: "cmd+c", &failures)
        expect("paste it", in: finder, isKeys: "cmd+v", &failures)
        // A binding that really does take an argument keeps taking it.
        if case .openURL(let url)? = Phrasebook.parse("go to facebook.com", in: finder)?.command {
            if !url.contains("facebook.com") {
                failures.append("“go to facebook.com” navigates to \(url)")
            }
        } else {
            failures.append("“go to facebook.com” no longer navigates")
        }
        if case .fillField? = Phrasebook.parse("fill email with a@b.com", in: finder)?.command {} else {
            failures.append("“fill email with a@b.com” no longer fills a field")
        }

        // MARK: Numbering came back, but as a different thing.
        //
        // The old overlay walked the accessibility tree and drew boxes on the
        // Mac; it was deleted with the rest of that machinery. What replaced
        // it asks Cua for the element list and draws the badges on the PHONE,
        // over its own screenshot. So "show numbers" resolves again — and
        // must resolve to .showNumbers and nothing else.
        for phrase in ["show numbers", "show guide", "numbers", "hide numbers"] {
            guard let hit = Phrasebook.parse(phrase, in: finder) else {
                failures.append("“\(phrase)” should ask for the numbers")
                continue
            }
            if case .sequence(_, let steps) = hit.command, steps.contains(where: {
                if case .showNumbers = $0 { return true }
                return false
            }) {
                continue
            }
            if case .showNumbers = hit.command { continue }
            failures.append("“\(phrase)” resolved to \(hit.description), not the numbers")
        }

        // These belonged to the deleted overlay and have no meaning now.
        for phrase in ["show boxes", "select 3"] {
            if let hit = Phrasebook.parse(phrase, in: finder) {
                failures.append("“\(phrase)” should no longer match, got \(hit.description)")
            }
        }

        // MARK: Regressions. Phrases the new entries sit closest to.
        expect("close this", in: finder, isKeys: "escape", &failures)
        expect("escape", in: finder, isKeys: "escape", &failures)
        expect("close tab", in: finder, isKeys: "cmd+w", &failures)
        expect("copy", in: finder, isKeys: "cmd+c", &failures)
        expect("select all", in: finder, isKeys: "cmd+a", &failures)

        // "click skip" must not become the media key for next track.
        //
        // It did, on a real page with a Skip button visible. The recogniser
        // offered both "Click skip" and "Skip"; SpeechRepair preferred the
        // one the literal parser recognised, and the literal parser only
        // recognises "skip" as a shortcut. The word "click" is the whole
        // signal that a control was meant, so it is asserted here.
        for press in ["click skip", "press skip", "tap skip", "hit skip",
                      "click next step", "select skip"] {
            if !JevIntent.startsWithPressVerb(press) {
                failures.append("press verb not recognised in “\(press)”")
            }
        }
        for shortcut in ["skip", "next track", "skip song", "volume up"] {
            if JevIntent.startsWithPressVerb(shortcut) {
                failures.append("“\(shortcut)” wrongly read as a press")
            }
        }
        // The bare word still means the media key — that is not the bug.
        //
        // Asserted by what it DOES, not merely that it does something. The
        // previous version only failed when parse returned nil, so "skip"
        // could have regressed to opening a URL and this would have passed.
        switch Phrasebook.parse("skip", in: finder)?.command {
        case .sequence(let label, _) where label.lowercased().contains("next"):
            break
        case .pressKeys, .systemAction:
            break
        case .none:
            failures.append("“skip” no longer parses at all")
        case .some(let other):
            failures.append("“skip” now means \(other) — it should still be the media key")
        }

        // The vocabulary keeps its words unless you say a verb.
        //
        // Letting a button on screen outrank a bare shortcut quietly took
        // "save", "back", "find", "copy" and "play" away from the Phrasebook
        // on any page that happened to have a button of that name. Only an
        // explicit press should divert to the screen.
        for bare in ["save", "copy", "paste", "undo", "back", "find",
                     "play", "skip", "next tab", "new tab", "reload"] {
            if JevIntent.startsWithPressVerb(bare) {
                failures.append("bare “\(bare)” must not read as a press")
            }
            if Phrasebook.parse(bare, in: finder) == nil && Phrasebook.parse(bare, in: plainWeb) == nil {
                failures.append("vocabulary lost “\(bare)”")
            }
        }

        // A command that is right but incomplete should ask, not give up.
        // "search" and "find" work bare — they just open the search box — so
        // they are complete commands, not unfinished ones.
        for phrase in ["go to tab", "set volume to", "type"] {
            if Phrasebook.awaitingArgument(phrase, in: finder) == nil
                && Phrasebook.awaitingArgument(phrase, in: plainWeb) == nil {
                failures.append("“\(phrase)” should ask for its missing value")
            }
        }
        // A complete command must never be turned into a question.
        for phrase in ["next tab", "copy", "mission control", "reload", "close tab"] {
            if Phrasebook.awaitingArgument(phrase, in: finder) != nil {
                failures.append("“\(phrase)” is complete and must not ask")
            }
        }
        // Neither should a sentence that already carries an argument.
        if Phrasebook.awaitingArgument("go to tab 3", in: finder) != nil {
            failures.append("“go to tab 3” already has its value")
        }

        // Nothing you dictate is ever written to disk or served over HTTP.
        //
        // Driven from the real Phrasebook, not from hand-written strings.
        // The previous version only fed the redactor inputs shaped to
        // trigger it, so it passed while "search for 4111 1111 1111 1111"
        // wrote the card number to commands.jsonl in three fields.
        let secret = "4111 1111 1111 1111"
        for phrase in ["type \(secret)", "say \(secret)", "search for \(secret)",
                       "find \(secret)", "new note \(secret)", "write \(secret)",
                       "go to bank.example/reset?token=\(secret)"] {
            guard let parsed = Phrasebook.parse(phrase, in: plainWeb)
                    ?? Phrasebook.parse(phrase, in: finder) else { continue }
            let carries = CommandJournal.carriesFreeText(parsed.command)
            for field in [CommandJournal.redacted(phrase, carriesText: carries),
                          CommandJournal.redacted(parsed.description, carriesText: carries)] {
                if field.contains("4111") {
                    failures.append("journal leaks “\(phrase)” as: \(field)")
                }
            }
        }
        // An ordinary command keeps its words.
        for plain in ["next tab", "close tab", "mission control"] {
            if CommandJournal.redacted(plain, carriesText: false) != plain {
                failures.append("redactor mangled “\(plain)”")
            }
        }

        // The three routes where nothing parsed, which is exactly where a
        // misheard secret lands. `redacted` keeps the first word as "the
        // verb"; here there is no verb, so the first word IS the value.
        for bare in [secret, "hunter2", "my pin is 4321"] {
            if CommandJournal.withheld(bare).contains(where: \.isNumber)
                || CommandJournal.withheld(bare).contains("hunter") {
                failures.append("unparsed route leaks “\(bare)” as: \(CommandJournal.withheld(bare))")
            }
        }
        // What is around the value still survives, so the line stays useful.
        let unparsed = CommandJournal.withheld("Did not understand “\(secret)” — no reading matched")
        if unparsed.contains("4111") || !unparsed.hasPrefix("Did not understand") {
            failures.append("unparsed reason came out as: \(unparsed)")
        }

        // The finishing route: "type" asked, and the answer arrives alone.
        // Keyed on the command the two halves make TOGETHER, because the
        // answer on its own has nothing to key on.
        if let joined = Phrasebook.parse("type hunter2", in: plainWeb)
                ?? Phrasebook.parse("type hunter2", in: finder) {
            if !CommandJournal.carriesFreeText(joined.command) {
                failures.append("a finished “type” is not recognised as carrying text")
            }
            let heard = CommandJournal.redacted("type hunter2",
                                                carriesText: CommandJournal.carriesFreeText(joined.command))
            if heard.contains("hunter") {
                failures.append("finishing route leaks the answer as: \(heard)")
            }
        }

        // The answer with no verb in front of it.
        //
        // Speech drops leading verbs constantly, and a pending "type" times
        // out after 30 s — so the model route regularly gets the bare value
        // and resolves the WHOLE transcript to .typeText. `redacted` then
        // kept the first word as "the verb", which was the secret.
        for bare in [secret, "hunter2"] {
            let asTyped = Command.typeText(text: bare)
            if !CommandJournal.startsWithTheValue(bare, asTyped) {
                failures.append("“\(bare)” typed whole is not recognised as all-value")
            }
        }
        // …and the ordinary case still keeps its verb, because the value
        // does not start where the sentence does.
        if CommandJournal.startsWithTheValue("search for \(secret)",
                                             .typeText(text: secret)) {
            failures.append("a real verb was mistaken for the value")
        }

        // The log file, not just the journal.
        //
        // Four rounds closed commands.jsonl and the fifth found the same
        // transcript written verbatim to jev.log one function earlier, by
        // the line that reports what speech heard — before anything has
        // interpreted it, so there is nothing to key a redaction on.
        // `shape` is the answer: how much was said, never what.
        for spoken in [secret, "hunter2", "my passphrase is banana"] {
            let line = JevLog.shape(spoken)
            if line.contains("4111") || line.contains("hunter") || line.contains("banana") {
                failures.append("the voice log leaks “\(spoken)” as: \(line)")
            }
            // Still says enough to debug with: how many words there were.
            // An exact character count is deliberately NOT here — the
            // length of a passphrase is a real fact about it.
            if !line.contains("word") {
                failures.append("the voice log says nothing useful about “\(spoken)”: \(line)")
            }
            if line.contains(String(spoken.count)) && spoken.count > 9 {
                failures.append("the voice log gives away the exact length of “\(spoken)”: \(line)")
            }
        }

        // A description is loggable only through the command-keyed path.
        // JevLog.safe cannot see inside “Search for “…”” — it keys on a
        // leading verb, and "Search for" is not one of them.
        for phrase in ["search for \(secret)", "type \(secret)"] {
            guard let parsed = Phrasebook.parse(phrase, in: plainWeb)
                    ?? Phrasebook.parse(phrase, in: finder) else { continue }
            let line = CommandJournal.safeDescription(parsed.description, parsed.command)
            if line.contains("4111") {
                failures.append("log line leaks “\(phrase)” as: \(line)")
            }
        }

        return failures
    }

    // MARK: - Expectations

    /// The phrasebook must decline, so the sentence reaches Jev intact rather
    /// than being truncated to its first verb.
    private static func expectNoMatch(_ phrase: String, in context: Phrasebook.Context,
                                      _ failures: inout [String]) {
        if let parsed = Phrasebook.parse(phrase, in: context) {
            failures.append("“\(phrase)” should not match the literal vocabulary, got \(parsed.description)")
        }
    }

    private static func expectForm(_ phrase: String, in context: Phrasebook.Context,
                                   _ failures: inout [String]) {
        guard let parsed = Phrasebook.parse(phrase, in: context) else {
            failures.append("“\(phrase)” does not parse at all"); return
        }
        if case .showForm = parsed.command { return }
        failures.append("“\(phrase)” should show the form, got \(parsed.description)")
    }

    private static func expect(_ phrase: String, in context: Phrasebook.Context,
                               isPointer kind: String, _ failures: inout [String]) {
        guard let parsed = Phrasebook.parse(phrase, in: context) else {
            failures.append("“\(phrase)” does not parse at all"); return
        }
        guard case .pointerAction(let actual) = parsed.command else {
            failures.append("“\(phrase)” should act on the pointer, got \(parsed.description)"); return
        }
        if actual != kind { failures.append("“\(phrase)” should \(kind), got \(actual)") }
    }

    private static func expect(_ phrase: String, in context: Phrasebook.Context,
                               isKeys spec: String, _ failures: inout [String]) {
        guard let parsed = Phrasebook.parse(phrase, in: context) else {
            failures.append("“\(phrase)” does not parse at all"); return
        }
        guard let actual = firstKeys(in: parsed.command) else {
            failures.append("“\(phrase)” should press \(spec), got \(parsed.description)"); return
        }
        if actual != spec { failures.append("“\(phrase)” should press \(spec), presses \(actual)") }
    }

    private static func expect(_ phrase: String, in context: Phrasebook.Context,
                               isSystemAction name: String, _ failures: inout [String]) {
        guard let parsed = Phrasebook.parse(phrase, in: context) else {
            failures.append("“\(phrase)” does not parse at all"); return
        }
        guard case .systemAction(let actual, _) = parsed.command else {
            failures.append("“\(phrase)” should be the system \(name), got \(parsed.description)"); return
        }
        if actual != name { failures.append("“\(phrase)” should be \(name), got \(actual)") }
    }

    private static func expectSecretPrompt(_ phrase: String, in context: Phrasebook.Context,
                                           secret: Bool, _ failures: inout [String]) {
        guard let parsed = Phrasebook.parse(phrase, in: context) else {
            failures.append("“\(phrase)” does not parse at all"); return
        }
        guard case .sequence(_, let steps) = parsed.command,
              let request = steps.compactMap({ step -> (String, Bool)? in
                  if case .requestInput(let field, let isSecret) = step { return (field, isSecret) }
                  return nil
              }).first else {
            failures.append("“\(phrase)” should ask the phone for text, got \(parsed.description)"); return
        }
        if request.1 != secret {
            failures.append("“\(phrase)” secret should be \(secret), got \(request.1)")
        }
    }

    private static func firstKeys(in command: Command) -> String? {
        switch command {
        case .pressKeys(let spec): return spec
        case .sequence(_, let steps): return steps.compactMap(firstKeys).first
        default: return nil
        }
    }
}
