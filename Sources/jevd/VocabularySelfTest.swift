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
        if case .rightClickControl(let label)? = Phrasebook.parse("right click the submit button", in: finder)?.command {
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
        // …which must still mean numbering the screen.
        if case .showHints? = Phrasebook.parse("show numbers", in: finder)?.command {} else {
            failures.append("“show numbers” no longer shows the numbered guides")
        }
        if case .showHints? = Phrasebook.parse("show boxes", in: finder)?.command {} else {
            failures.append("“show boxes” no longer shows the numbered guides")
        }

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

        // MARK: Taking the numbers down again.
        for phrase in ["hide numbers", "hide boxes", "clear boxes", "never mind"] {
            if case .hideHints? = Phrasebook.parse(phrase, in: finder)?.command {} else {
                failures.append("“\(phrase)” should hide the numbers, got "
                    + (Phrasebook.parse(phrase, in: finder)?.description ?? "no match"))
            }
        }

        // MARK: Regressions. Phrases the new entries sit closest to.
        expect("close this", in: finder, isKeys: "escape", &failures)
        expect("escape", in: finder, isKeys: "escape", &failures)
        expect("close tab", in: finder, isKeys: "cmd+w", &failures)
        expect("copy", in: finder, isKeys: "cmd+c", &failures)
        expect("select all", in: finder, isKeys: "cmd+a", &failures)

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
