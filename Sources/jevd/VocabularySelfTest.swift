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
            base64Audio: "AAAA", mimeType: "audio/aac",
            vocabulary: ["Ghostty", "command 1"], languageCodes: ["en-PH"])
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

        // One language setting governs both recognisers. It is safe to send
        // HERE and not everywhere: on the newer interactions surface a
        // language code silently reverts `mode: "smart"` to verbatim, with
        // HTTP 200 and no signal. jev uses neither that surface nor that mode.
        if (audioConfig?["languageCodes"] as? [String]) != ["en-PH"] {
            failures.append("gemini: the chosen language is not being sent")
        }
        // Empty is a value, not an omission: it is how this API is asked to
        // detect the language itself, which is what someone switching between
        // English and Tagalog mid-sentence needs.
        let auto = GeminiTranscriber.requestBody(
            base64Audio: "AAAA", mimeType: "audio/aac", vocabulary: [], languageCodes: [])
        let autoGeneration = auto["generationConfig"] as? [String: Any]
        let autoConfig = autoGeneration?["audioTranscriptionConfig"] as? [String: Any]
        if (autoConfig?["languageCodes"] as? [String]) != [] {
            failures.append("gemini: auto-detect must send an empty list, not nothing")
        }

        // "auto" is not a locale, so Apple must never be handed it.
        let appleWouldUse = VoiceLocale.resolve(chosen: VoiceLocale.autoDetect,
                                                system: "en_PH",
                                                supported: ["en-PH", "en-US"])
        if appleWouldUse == VoiceLocale.autoDetect {
            failures.append("voice locale: auto leaked into the system recogniser")
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

        // MARK: A reply is believed only if it is a real choice over what was sent.
        //
        // The browser loop checked this since it was written. The sentence
        // resolver — the code that decides whether to open a URL or hand a
        // signed-in shop to an agent — applied none of it, and read one scalar
        // off a distribution it never looked at. "click free shipping to
        // philippines" died at operation=0.57 with the right control at 0.78
        // in the same reply.
        typealias Answer = JevAPI.ChoiceAnswer
        let offered: Set<String> = ["a", "b", "c"]
        func answer(_ c: String, _ p: [String: Double], conf: Double = 0.9) -> Answer {
            Answer(choice: c, confidence: conf, probabilities: p)
        }
        func soundness(_ name: String, _ a: Answer, _ expected: Bool) {
            if a.isSound(offered: offered) != expected { failures.append("sound: \(name)") }
        }
        soundness("a real choice is sound", answer("a", ["a": 0.7, "b": 0.2, "c": 0.1]), true)
        soundness("a choice outside the set is not", answer("z", ["a": 0.7, "b": 0.2, "c": 0.1]), false)
        soundness("a distribution over other keys is not", answer("a", ["a": 0.5, "z": 0.5]), false)
        soundness("not summing to one is not", answer("a", ["a": 0.5, "b": 0.1, "c": 0.1]), false)
        soundness("an argmax disagreeing with the choice is not",
                  answer("a", ["a": 0.2, "b": 0.7, "c": 0.1]), false)
        soundness("a non-finite number is not", answer("a", ["a": .nan, "b": 0.5, "c": 0.5]), false)

        // Decisive means "beat the runner-up by twice", at any size.
        func decisive(_ name: String, _ a: Answer, _ expected: Bool) {
            if a.isDecisive != expected { failures.append("decisive: \(name)") }
        }
        decisive("a clear lead is decisive", answer("a", ["a": 0.7, "b": 0.2, "c": 0.1]), true)
        decisive("a toss-up is not", answer("a", ["a": 0.5, "b": 0.45, "c": 0.05]), false)
        decisive("one of sixty at 0.3 is decisive", Answer(
            choice: "1", confidence: 0.3,
            probabilities: Dictionary(uniqueKeysWithValues: (1...60).map {
                (String($0), $0 == 1 ? 0.3 : 0.7 / 59) })), true)
        decisive("98 to 2 is decisive", answer("a", ["a": 0.98, "b": 0.02]), true)
        decisive("a single option has no margin", answer("a", ["a": 1.0]), false)

        // The offered set is recovered from the question, so a reply is
        // checked against what was actually sent.
        if JevAPI.Question.choice(instructions: "", labels: ["x", "y"]).offeredLabels != ["x", "y"] {
            failures.append("offered: a choice question does not report its labels")
        }
        if JevAPI.Question.describedChoice(instructions: "", options: ["1": [:], "2": [:]])
            .offeredLabels != ["1", "2"] {
            failures.append("offered: a described choice does not report its keys")
        }
        if JevAPI.Question.noul(instructions: "").offeredLabels != nil {
            failures.append("offered: a yes/no question claims labels")
        }

        // An unsound reply is no answer — and the resolver must treat it so
        // rather than believe it or crash on it.
        let replies = JevAPI.Answers(
            choices: ["q": answer("z", ["a": 0.7, "b": 0.2, "c": 0.1])], nouls: [:])
        if replies.soundChoice("q", offered: offered) != nil {
            failures.append("sound: an unsound reply was believed")
        }
        if replies.soundChoice("missing", offered: offered) != nil {
            failures.append("sound: a missing reply was invented")
        }
        if replies.soundChoice("q", offered: nil as Set<String>?) != nil {
            failures.append("sound: a reply to a question with no options was believed")
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
        // Certain, so the phrasebook keeps it: instant, offline, no call.
        for place in ["youtube dot com", "github.com", "https://example.com/x",
                      "news dot ycombinator dot com",
                      "docs dot google dot com slash spreadsheets",
                      "bath and body works dot com", "playstation dot com",
                      "searchencrypt dot com",
                      // Named in a list this code owns, so no judgement is
                      // being exercised — the same list a web task starts
                      // from, so both agree where youtube is.
                      "youtube", "amazon", "wikipedia", "stack overflow"] {
            destination("certain: \(place)", place, true)
        }

        // NOT certain, so the classifier decides. Every one of these used to
        // become a domain, because the guess stripped the spaces and appended
        // ".com". Three were reported from a real phone:
        //     "go to YouTube and search hello"     -> youtubeandsearchhello.com
        //     "go to youtube dot com and search …" -> youtube.comandsearchhellboy
        //     "go to workspace three"              -> workspacethree.com
        // Each was fixed by making the guess cleverer and the next phrasing
        // broke it again. The guess is gone; jev classifies these instead,
        // measured at 0.98 and above on exactly these sentences.
        for uncertain in ["youtube and search hello",
                          "youtube dot com and search hellboy",
                          "youtube and play lofi",
                          "amazon and buy coffee filters",
                          "amazon dot com and add coffee filters to my cart",
                          "github and find the jev repo",
                          "youtube then play something",
                          "twitter and post a reply",
                          "netflix and watch something",
                          "workspace three", "workspace 3", "to workspace two",
                          "my account settings page",
                          "settings", "the top", "my inbox",
                          "facebook", "the verge", "some place nobody named",
                          ""] {
            destination("not certain: \(uncertain)", uncertain, false)
        }

        // End to end, which is the only version of this that matters: the
        // whole sentence, through the real parser, to the command that runs.
        func resolves(_ sentence: String, _ describe: (Command?) -> Bool, _ what: String) {
            let parsed = VoiceCommand.parse(sentence)
            if !describe(parsed?.command) {
                failures.append("sentence: “\(sentence)” did not become \(what)")
            }
        }
        resolves("go to workspace three", {
            if case .switchWorkspace(let id) = $0 { return id == "3" }
            return false
        }, "a workspace switch")
        resolves("go to workspace 2", {
            if case .switchWorkspace(let id) = $0 { return id == "2" }
            return false
        }, "a workspace switch")
        resolves("go to github dot com", {
            if case .openURL(let url) = $0 { return url == "https://github.com" }
            return false
        }, "an open of github.com")
        // Deliberately not asserted for a bare site name: that binding also
        // requires a browser to be frontmost, and what is frontmost during a
        // launch assertion is not a browser. Scope decides it, which is the
        // right behaviour and the wrong thing to pin here.
        // The three that became invented domains. Nothing local should claim
        // them now — they belong to the classifier.
        for guessed in ["go to youtube and search hello",
                        "go to youtube dot com and search hellboy"] {
            resolves(guessed, { command in
                if case .openURL = command { return false }
                return true
            }, "anything but an invented address")
        }

        // The transform itself, which is where the bug always was. It used to
        // return String and could not refuse; now it returns nil for anything
        // it would have had to guess at. One rule: if a dot was said, nothing
        // may follow the last label; if not, it must be one word.
        func host(_ name: String, _ spoken: String, _ expected: String?) {
            let got = Phrasebook.normalisedDestination(spoken)
            if got != expected { failures.append("host: \(name) gave \(got ?? "nil")") }
        }
        host("a spoken address", "github dot com", "github.com")
        host("a written address", "github.com", "github.com")
        host("a scheme is stripped, not doubled", "https://example.com", "example.com")
        host("a spoken path", "docs dot google dot com slash spreadsheets",
             "docs.google.com/spreadsheets")
        host("one word is a guess worth making", "facebook", "facebook.com")
        host("a filler is dropped", "to the verge dot com", "theverge.com")
        // The TLD is last, so everything before it is the host.
        host("a multi-word name ending in dot com collapses",
             "bath and body works dot com", "bathandbodyworks.com")
        // A known site gets its real address, not a guess.
        host("a known site resolves to its real host", "stack overflow", "stackoverflow.com")
        host("youtube resolves to www", "youtube", "www.youtube.com")

        // Every one of these was, or would have been, invented and opened.
        host("words after the TLD are a task", "youtube dot com and search hellboy", nil)
        host("…with a verb the list never had", "youtube dot com and look for hellboy", nil)
        host("two words with no dot are not a domain", "workspace three", nil)
        host("a sentence is not a domain", "my bank and check the balance", nil)
        host("a path with spaces was never spelled out", "example dot com slash some page", nil)
        host("a lone tld is nothing", "dot com", nil)
        host("punctuation is not a host", "what?!", nil)
        host("empty is nothing", "", nil)

        // End to end, through the real parser. Both of these reached the
        // transform with NO guard at all and became domains.
        resolves("sign in to my bank and check the balance", { command in
            if case .openURL = command { return false }
            if case .sequence(_, let steps) = command {
                return !steps.contains { if case .openURL = $0 { return true }; return false }
            }
            return true
        }, "anything but an invented address")
        resolves("go to youtube dot com and look for hellboy", { command in
            if case .openURL = command { return false }
            return true
        }, "anything but an invented address")

        // A workspace binding now exists, so the catalogue can offer one and
        // the classifier can choose one — and a bare "switch workspace" asks
        // "Which workspace?" instead of being nothing, which the prompt code
        // promised and could never do.
        resolves("switch workspace 3", {
            if case .switchWorkspace(let id) = $0 { return id == "3" }; return false
        }, "a workspace switch")
        resolves("switch to workspace seven", {
            if case .switchWorkspace(let id) = $0 { return id == "7" }; return false
        }, "a workspace switch")
        if Phrasebook.awaitingArgument("switch workspace", in: Phrasebook.neutral) == nil {
            failures.append("workspace: a bare 'switch workspace' no longer asks which")
        }
        if VoiceCommand.parse("switch workspace", in: Phrasebook.neutral) != nil {
            failures.append("workspace: a bare 'switch workspace' ran something")
        }

        // What a word means HERE is offered to the classifier, and builds back
        // as that meaning. Six profiles hold thirty-three scoped phrases; the
        // catalogue used to offer none of them.
        let youtube = Phrasebook.Context(bundleId: "com.google.Chrome", appName: "Google Chrome",
                                         isBrowserLike: true, host: "youtube.com")
        let scopedPhrases = AppProfiles.phrases(bundleId: youtube.bundleId, host: youtube.host)
        if scopedPhrases.isEmpty {
            failures.append("profiles: youtube in chrome has no scoped phrases")
        }
        let catalogue = Phrasebook.catalog(in: youtube)
        for phrase in scopedPhrases where !catalogue.contains(phrase) {
            failures.append("profiles: “\(phrase)” is not offered where it applies")
        }
        for phrase in scopedPhrases.prefix(5)
        where Phrasebook.build(canonical: phrase, in: youtube) == nil {
            failures.append("profiles: “\(phrase)” was offered and cannot be built")
        }
        if Set(catalogue).count != catalogue.count {
            failures.append("catalogue: repeats itself")
        }
        // …and is NOT offered where it does not apply.
        let finder = Phrasebook.Context(bundleId: "com.apple.finder", appName: "Finder",
                                        isBrowserLike: false)
        let elsewhere = Set(Phrasebook.catalog(in: finder))
        let leaked = scopedPhrases.filter { elsewhere.contains($0) }
            .filter { AppProfiles.phrases(bundleId: finder.bundleId, host: nil).contains($0) == false }
        // A phrase can legitimately be both global and scoped; only one that
        // exists ONLY for youtube must be absent in Finder.
        let globalOnly = Set(Phrasebook.catalog(in: Phrasebook.neutral))
        for phrase in leaked where !globalOnly.contains(phrase) {
            failures.append("profiles: “\(phrase)” is offered in Finder")
        }

        // The parser that "go to workspace three" was stealing from.
        if VoiceCommand.workspaceId(in: "go to workspace three") != "3" {
            failures.append("workspace: spoken digits are not understood")
        }
        if VoiceCommand.workspaceId(in: "go to github dot com") != nil {
            failures.append("workspace: a plain address is being claimed")
        }


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
