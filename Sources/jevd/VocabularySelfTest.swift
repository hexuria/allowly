import Foundation
import JevCore
import JevDecide

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

        // MARK: Transcription by Gemini, when there is a key for it.
        //
        // Both of the traps here fail SILENTLY — the request succeeds and the
        // transcript is empty — so they are assertions rather than comments.
        // Learned from Google's own demo client, not from the documentation.
        let body = GeminiTranscriber.requestBody(
            base64Audio: "AAAA", mimeType: "audio/aac", vocabulary: ["Ghostty", "command 1"])
        let generation = body["generationConfig"] as? [String: Any]
        let audioConfig = generation?["audioTranscriptionConfig"] as? [String: Any]

        // Without this the call returns 200 and an empty transcript.
        if audioConfig?["wordTimestamp"] as? Bool != true {
            failures.append("gemini: wordTimestamp must be true or the transcript is empty")
        }
        // `mode` parses on this endpoint and then returns nothing. It belongs
        // only on the newer interactions surface, which jev does not use.
        if audioConfig?["mode"] != nil {
            failures.append("gemini: mode does not work on this endpoint")
        }
        if generation?["temperature"] as? Int != 0 {
            failures.append("gemini: transcription must not be sampled")
        }
        // The hint list is the one thing that reliably rescues a short unusual
        // word, and it carries over to Gemini as a custom vocabulary.
        if (audioConfig?["customVocabulary"] as? [String])?.contains("Ghostty") != true {
            failures.append("gemini: the vocabulary is not being sent")
        }
        if (try? JSONSerialization.data(withJSONObject: body)) == nil {
            failures.append("gemini: the request body does not serialise")
        }

        // Where the key lives. Namespaced so it cannot collide with a saved
        // detail or the pairing token, and describable without being shown.
        if GeminiTranscriber.keychainKey == PersonalDetails.storageKey(for: "email") {
            failures.append("gemini: the key collides with a saved detail")
        }
        if GeminiTranscriber.sourceDescription().count > 40 {
            failures.append("gemini: the source description is too long for a menu")
        }
        // A description of where the key is must never be able to contain the
        // key. It is built from three fixed strings; this holds that.
        for source in ["from the environment", "in your Keychain", "from a file"]
        where source.contains(where: { $0.isNumber }) {
            failures.append("gemini: a source description carries a value")
        }
        // Naming the model is how the menu says which recogniser is in use,
        // so it must never be empty.
        if GeminiTranscriber.model.isEmpty {
            failures.append("gemini: no model named")
        }

        // The phone calls everything ".webm" and sends MP4, so the container
        // is sniffed. An unknown type is refused rather than guessed: a wrong
        // guess is a failed request, and falling back is better than that.
        func mime(_ ext: String, _ expected: String?) {
            if GeminiTranscriber.mimeType(forExtension: ext) != expected {
                failures.append("gemini: \(ext) maps wrongly")
            }
        }
        mime("m4a", "audio/aac")
        mime("M4A", "audio/aac")
        mime("wav", "audio/wav")
        mime("flac", "audio/flac")
        // Not in Gemini's list, and jev already transcodes it for Apple too.
        mime("webm", nil)
        mime("txt", nil)
        mime("", nil)

        // The reply, including the shapes that are not a transcript.
        func transcript(_ name: String, _ json: String, _ expected: String?) {
            if GeminiTranscriber.transcript(fromBody: Data(json.utf8)) != expected {
                failures.append("gemini: \(name)")
            }
        }
        transcript("a normal reply yields its text",
                   #"{"candidates":[{"content":{"parts":[{"text":"close tab"}]}}]}"#, "close tab")
        transcript("parts are joined",
                   #"{"candidates":[{"content":{"parts":[{"text":"close "},{"text":"tab"}]}}]}"#,
                   "close tab")
        // The silent failure this is all guarding against: a 200 with nothing
        // in it must read as "nothing heard", never as an empty command.
        transcript("an empty part is nothing heard",
                   #"{"candidates":[{"content":{"parts":[{"text":"   "}]}}]}"#, nil)
        transcript("no candidates is nothing heard", #"{"candidates":[]}"#, nil)
        transcript("an error body is nothing heard", #"{"error":{"code":403}}"#, nil)
        transcript("malformed JSON is nothing heard", "not json", nil)

        // MARK: What the recogniser is told to expect.
        //
        // Measured, on a Mac already listening in en-PH: "press cmd 1" came
        // back as "prayers for man one", and "create new tab" as "create new
        // dog". The first had no chance — keystroke words were never in the
        // hint list at all. The second was: "new tab" is in there, and at a
        // budget of 200 the biasing had been diluted to the point of not
        // defending even the phrases it contained.
        let hints = Transcription.recognitionHints()
        func hinted(_ name: String, _ phrase: String) {
            if !hints.contains(where: { $0.caseInsensitiveCompare(phrase) == .orderedSame }) {
                failures.append("hint: \(name) — \(phrase) is not offered")
            }
        }
        hinted("the press verb", "press")
        hinted("the command key", "command")
        hinted("its short form", "cmd")
        hinted("a modifier", "shift")
        hinted("a named key", "escape")
        hinted("a whole shortcut", "command 1")
        hinted("and the last one", "command 9")
        // A bare digit is deliberately absent. "1" competes with every number
        // anyone might say and biases nothing in particular, while spending a
        // slot that "command 1" uses better.
        if hints.contains("1") {
            failures.append("hint: a bare digit is spending a slot")
        }
        hinted("the tab key, which is also a browser tab", "tab")
        hinted("the phrase that came back as 'new dog'", "new tab")

        // Biasing weakens as the list grows: every extra phrase competes with
        // the ones that matter. The cap is the point, not an implementation
        // detail, so it is asserted.
        if hints.count > Transcription.hintBudget {
            failures.append("hint: \(hints.count) phrases exceeds the budget")
        }
        if Transcription.hintBudget > 120 {
            failures.append("hint: the budget is large enough to dilute itself")
        }
        // Duplicates spend the budget twice on one word.
        if Set(hints.map { $0.lowercased() }).count != hints.count {
            failures.append("hint: the list repeats itself")
        }
        if hints.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            failures.append("hint: an empty phrase takes a slot and biases nothing")
        }

        // MARK: Saying "click X" means clicking X.
        //
        // Measured on a real Amazon page: "click free shipping to philippines"
        // came back as control=Free Shipping Zone@0.78 alongside
        // operation=web_task@0.57. The right link, named correctly from words
        // that do not appear in its label — and then refused, because the
        // web-task floor rejected 0.57 while the answer sat in the same reply.
        // A pressing verb plus a control named with more conviction than the
        // operation now wins.
        func pressVerb(_ name: String, _ text: String, _ expected: Bool) {
            if JevIntent.startsWithPressVerb(text) != expected {
                failures.append("press verb: \(name)")
            }
        }
        for verb in ["click", "press", "tap", "push", "hit", "choose", "select"] {
            pressVerb("\(verb) is a press", "\(verb) free shipping to philippines", true)
        }
        pressVerb("case does not matter", "Click Free Shipping Zone", true)
        // These must NOT be treated as presses, or a web goal gets turned into
        // a click on whatever happens to match on screen.
        pressVerb("going somewhere is not a press", "go to youtube and search hello", false)
        pressVerb("playing is not a press", "play a lofi radio on youtube", false)
        pressVerb("searching is not a press", "search amazon for coffee filters", false)
        // A word that merely begins with a press verb is not one.
        pressVerb("clicked is not click", "clicking through the results", false)
        pressVerb("selective is not select", "selective search on amazon", false)

        // MARK: Where decisions are allowed to be sent.
        //
        // The endpoint can be pointed at something local that strips personal
        // data out first. That override must not be able to WIDEN where the
        // data goes: a browser task sends the page's text and every control's
        // label, and on a signed-in page those carry a name and an address.
        func loopback(_ name: String, _ text: String, _ expected: Bool) {
            guard let url = URL(string: text) else {
                if expected { failures.append("endpoint: \(name) did not parse") }
                return
            }
            if JevAPI.isLoopback(url) != expected { failures.append("endpoint: \(name)") }
        }
        loopback("the loopback address is local", "http://127.0.0.1:8799/v1/systemone", true)
        loopback("localhost is local", "http://localhost:8799/v1/systemone", true)
        loopback("IPv6 loopback is local", "http://[::1]:8799/v1/systemone", true)
        loopback("another machine is not", "http://192.168.1.50:8799/v1/systemone", false)
        loopback("a hostname is not", "https://evil.example/v1/systemone", false)
        // The classic near-miss: a host that merely begins with the loopback
        // address, or embeds it in a username.
        loopback("a lookalike host is not local", "http://127.0.0.1.evil.example/x", false)
        loopback("userinfo does not make it local", "http://127.0.0.1@evil.example/x", false)
        loopback("a non-http scheme is not accepted", "file:///etc/passwd", false)

        // MARK: Which language the recogniser listens in.
        //
        // This was pinned to en-US. On a Mac set to en_PH that runs
        // Filipino-accented English through a model trained on American
        // English, and nothing downstream recovers a word never heard. The
        // fallback ORDER is what matters: a recogniser that will not start is
        // worse than one with the wrong accent.
        func resolves(_ name: String, chosen: String?, system: String,
                      supported: [String], expected: String) {
            let got = VoiceLocale.resolve(chosen: chosen, system: system,
                                          supported: Set(supported))
            if got != expected { failures.append("voice locale: \(name) gave \(got)") }
        }
        let apple = ["en-AU", "en-GB", "en-IN", "en-PH", "en-US", "fr-FR", "tl-PH"]

        resolves("a choice is honoured", chosen: "en-PH", system: "en_US",
                 supported: apple, expected: "en-PH")
        resolves("no choice follows this Mac", chosen: nil, system: "en_PH",
                 supported: apple, expected: "en-PH")
        // Locale identifiers use an underscore and speech uses a hyphen; they
        // are the same language and did not match.
        resolves("an underscore identifier still matches", chosen: nil, system: "en_PH",
                 supported: apple, expected: "en-PH")
        resolves("a choice that is no longer supported falls back",
                 chosen: "en-ZZ", system: "en_PH", supported: apple, expected: "en-PH")
        // A region with no model of its own should stay in its language
        // rather than landing somewhere random.
        resolves("an unsupported region keeps the language", chosen: nil, system: "en_NG",
                 supported: apple, expected: "en-US")
        resolves("a language with no English fallback takes what it has",
                 chosen: nil, system: "fr_CA", supported: apple, expected: "fr-FR")
        resolves("a language with nothing at all still starts",
                 chosen: nil, system: "ja_JP", supported: apple, expected: "en-US")
        // The last resort has to resolve to something the system actually has.
        resolves("even without en-US it picks something real", chosen: nil, system: "ja_JP",
                 supported: ["fr-FR", "tl-PH"], expected: "fr-FR")

        // MARK: "go to X" must be naming a place, not describing a task.
        //
        // `normalisedDestination` strips every space and appends ".com" to
        // anything without a dot. That is right for "go to facebook" and
        // catastrophic for a sentence: said aloud on a real phone, "go to
        // YouTube and search hello" became `youtubeandsearchhello.com` — a
        // domain invented out of the words. The binding claimed it because a
        // browser was frontmost, which is true of every browser task.
        func destination(_ name: String, _ text: String, _ expected: Bool) {
            if Phrasebook.namesADestination(text) != expected {
                failures.append("destination: \(name)")
            }
        }
        // Written or spoken, an address opens a page.
        for place in ["youtube dot com", "github.com", "https://example.com/x",
                      "facebook", "youtube", "stack overflow", "to the verge",
                      "my gmail", "news dot ycombinator dot com", "amazon", "wikipedia",
                      "docs dot google dot com slash spreadsheets",
                      // "and" sits inside real names too, so it cannot
                      // disqualify an address on its own.
                      "bath and body works dot com"] {
            destination("a place: \(place)", place, true)
        }

        // Everything here was, or would have been, turned into a domain.
        // Both of the first two were said aloud on a real phone:
        //     "go to YouTube and search hello"  -> youtubeandsearchhello.com
        //     "go to youtube dot com and search hellboy"
        //                                       -> youtube.comandsearchhellboy
        // The second survived the first fix, because that fix asked "is there
        // a dot?" before "is this more than one instruction?" — and a spoken
        // address contains " dot ". A task is recognised first now.
        for task in ["youtube and search hello",
                     "youtube dot com and search hellboy",
                     "youtube dot com and search hell boy",
                     "youtube and play lofi",
                     "amazon and buy coffee filters",
                     "amazon dot com and add coffee filters to my cart",
                     "github and find the jev repo",
                     "youtube then play something",
                     "twitter and post a reply",
                     "reddit and scroll to the top",
                     "my email and reply to the last one",
                     "google and search for weather",
                     "netflix and watch something",
                     "youtube dot com and subscribe to that channel",
                     "my account settings page",
                     ""] {
            destination("a task: \(task)", task, false)
        }

        // When the fast path declines, the resolver asks the model — and the
        // ADDRESS is still built here, from what the person said, never
        // returned by the model. A model that answered with a URL would be
        // producing something executable, which is exactly the freedom
        // withheld from it everywhere else.
        func spoken(_ name: String, _ sentence: String, _ expected: String?) {
            let got = Phrasebook.destination(fromSpoken: sentence)
            if got != expected {
                failures.append("spoken destination: \(name) gave \(got ?? "nil")")
            }
        }
        spoken("a lead verb is dropped", "go to github dot com", "github.com")
        spoken("visit works too", "visit stack overflow", "stackoverflow.com")
        spoken("browse to works too", "browse to facebook", "facebook.com")
        spoken("a trailing 'website' is not part of the host",
               "go to the new york times website", "newyorktimes.com")
        spoken("a trailing 'page' is not part of the host",
               "open the wikipedia page", "wikipedia.com")
        spoken("a name with and survives", "open bath and body works dot com",
               "bathandbodyworks.com")
        spoken("nothing but a verb is not a destination", "go to", nil)
        spoken("an empty sentence is not a destination", "", nil)

        // Whole words only, or a domain loses to a verb hiding inside it.
        destination("playstation is not play", "playstation dot com", true)
        destination("searchencrypt is not search", "searchencrypt dot com", true)

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
