import Foundation
import AppKit
import JevCore
import JevWeb

/// The literal vocabulary: phrases that map to a fixed sequence of steps.
///
/// Everything here is deterministic and costs no model call. Jev is for the
/// ambiguous remainder, not for "new tab".
///
/// Shortcuts differ between apps, so the table is keyed by bundle id with a
/// sensible default. Browsers and Electron apps share most of their bindings
/// because Electron is Chromium.
enum Phrasebook {
    struct Binding {
        let phrases: [String]
        /// Built from the trailing argument, when the phrase takes one.
        let build: (String, Context) -> VoiceCommand.Parsed?
    }

    struct Context {
        let bundleId: String
        let appName: String
        let isBrowserLike: Bool
        /// The host of the frontmost tab, when the app is a scriptable browser.
        /// Carried explicitly so parsing can be tested without a live browser.
        let host: String?

        init(bundleId: String, appName: String, isBrowserLike: Bool, host: String? = nil) {
            self.bundleId = bundleId
            self.appName = appName
            self.isBrowserLike = isBrowserLike
            self.host = host
        }
    }

    static func context() -> Context {
        let app = NSWorkspace.shared.frontmostApplication
        let bundleId = app?.bundleIdentifier ?? ""
        let browserish = [
            "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser",
            "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser",
            "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
        ]
        // Electron apps are Chromium, so they take the same bindings.
        let isElectron = FileManager.default.fileExists(
            atPath: (app?.bundleURL?.path ?? "") + "/Contents/Frameworks/Electron Framework.framework")
        return Context(
            bundleId: bundleId,
            appName: app?.localizedName ?? "the frontmost app",
            isBrowserLike: browserish.contains(bundleId) || isElectron,
            host: BrowserContext.currentHost()
        )
    }

    /// Match a phrase. Longest phrases first so "close tab" beats "close".
    static func parse(_ raw: String, in explicitContext: Context? = nil) -> VoiceCommand.Parsed? {
        let text = raw.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        guard !text.isEmpty else { return nil }
        let context = explicitContext ?? self.context()

        // Scope first. Where you are standing can redefine a bare word —
        // "mute" on YouTube is the video, not the Mac — and that has to be
        // decided before the generic, system-wide table gets a look.
        if let scoped = AppProfiles.override(for: text, in: context) {
            return scoped
        }

        let ordered = bindings.sorted { ($0.phrases.first?.count ?? 0) > ($1.phrases.first?.count ?? 0) }

        for binding in ordered {
            for phrase in binding.phrases {
                if text == phrase {
                    if let parsed = binding.build("", context) { return parsed }
                }
                if text.hasPrefix(phrase + " ") {
                    let argument = String(text.dropFirst(phrase.count + 1)).trimmingCharacters(in: .whitespaces)
                    if let parsed = build(binding, argument, context) { return parsed }
                }
            }
        }

        // Nothing matched exactly. Speech mangles short words constantly —
        // "close tab" arrives as "close thab", "select all" as "select owl" —
        // so try again allowing a small number of wrong letters.
        return nearMatch(text, in: ordered, context: context)
    }

    /// Does the table claim this sentence WORD FOR WORD?
    ///
    /// `parse` falls back to `nearMatch`, which is right for speech —
    /// "close thab" should still close the tab — and wrong as a
    /// precedence test. The on-screen control gate asks "is this
    /// sentence already spoken for?", and answering yes on a fuzzy
    /// guess costs the user a button press: with a Home link on screen,
    /// "click home" is within `nearMatch`'s budget of a binding and was
    /// being answered with a pointer click at wherever the cursor had
    /// been left. Measured over 43 ordinary button labels, 20 of them
    /// were taken that way.
    ///
    /// So the gate asks this instead, which is the exact loop above and
    /// nothing else.
    /// A context that names no app, for callers that must not ask.
    ///
    /// `context()` shells out to `osascript` and sends an Apple Event
    /// to whatever browser is frontmost — which is why it is kept off
    /// the hot path. A startup self-test reaching it was measured
    /// firing a live Apple Event during `self-tests`, where it can also
    /// raise a TCC prompt and block launch behind a wedged browser.
    static let neutral = Context(bundleId: "", appName: "", isBrowserLike: false)

    static func claimsExactly(_ text: String, in explicitContext: Context? = nil) -> Bool {
        // Trimmed the same way `parse` and `controlPhrase` trim, or one
        // full stop defeats the whole precedence rule: measured,
        // `claimsExactly("click away.")` was false while
        // `parse("click away.")` was Escape and the gate went on to
        // press a control named "Away".
        let text = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        guard !text.isEmpty else { return false }
        let context = explicitContext ?? self.context()
        if AppProfiles.override(for: text, in: context) != nil { return true }
        for binding in bindings {
            for phrase in binding.phrases {
                // The binding must actually BUILD something.
                //
                // Claiming on the prefix alone made the gate looser
                // than the thing it defers to: `parse` runs this same
                // loop and then requires `build` to succeed, so a
                // sentence like "print invoice" was claimed here,
                // declined there, and pressed nothing — measured
                // across an ordinary class of labels ("Save Draft",
                // "Copy Link", "Cancel Order", "This Week"), every one
                // of which used to work.
                if text == phrase, binding.build("", context) != nil { return true }
                if text.hasPrefix(phrase + " ") {
                    let argument = String(text.dropFirst(phrase.count + 1))
                        .trimmingCharacters(in: .whitespaces)
                    if build(binding, argument, context) != nil { return true }
                }
            }
        }
        return false
    }

    /// Match a phrase allowing a few wrong characters, budgeted by length so
    /// short phrases cannot collide with each other.
    private static func nearMatch(_ text: String, in ordered: [Binding],
                                  context: Context) -> VoiceCommand.Parsed? {
        let words = text.split(separator: " ").map(String.init)
        var best: (parsed: VoiceCommand.Parsed, distance: Int)?

        for binding in ordered {
            for phrase in binding.phrases {
                let phraseWordCount = phrase.split(separator: " ").count
                guard words.count >= phraseWordCount else { continue }

                let head = words.prefix(phraseWordCount).joined(separator: " ")
                let budget = phrase.count <= 8 ? 1 : (phrase.count <= 16 ? 2 : 3)
                let distance = AppCatalog.editDistance(phrase, head)
                guard distance <= budget else { continue }

                let argument = words.dropFirst(phraseWordCount).joined(separator: " ")
                guard let parsed = build(binding, argument, context) else { continue }
                if best == nil || distance < best!.distance {
                    best = (parsed, distance)
                }
            }
        }
        return best?.parsed
    }

    /// The phrase this sentence matched that wants a value it was not given.
    ///
    /// "switch workspace" and "go to tab" are perfectly good commands with a
    /// number missing. Today they parse to nothing and come back as "did not
    /// understand", so the whole sentence has to be said again — which is a
    /// silly thing to demand when the only missing part is "2".
    ///
    /// No table of which phrase needs what: the binding is simply asked. If
    /// it refuses an empty argument but accepts a sample one, then it needs
    /// an argument, and that is true by construction for every binding
    /// present and any added later.
    static func awaitingArgument(_ text: String, in context: Context) -> String? {
        let cleaned = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        guard !cleaned.isEmpty else { return nil }

        for binding in bindings {
            for phrase in binding.phrases {
                // The whole sentence must BE the phrase. A sentence with a
                // trailing argument that failed to parse is a different
                // problem and must not be turned into a question.
                guard cleaned == phrase else { continue }
                guard binding.build("", context) == nil else { continue }
                // Would it work with something? Numbers cover the counted
                // phrases, a word covers the rest.
                let accepts = ["2", "hello"].contains { binding.build($0, context) != nil }
                if accepts { return phrase }
            }
        }
        return nil
    }

    /// Build a binding from a trailing argument, refusing the match when the
    /// binding does not actually use it.
    ///
    /// Matching is prefix-based, and most bindings ignore their argument — so
    /// "copy" matched "copy the link and open a new tab" and did nothing but
    /// copy, silently dropping the rest of the sentence. Worse, "delete all"
    /// matched "delete all the files in my downloads folder" and pressed
    /// ⌘A then Delete. A binding that throws its argument away has not
    /// understood the sentence and must not claim it.
    ///
    /// Trailing politeness is the exception: "copy please" really is "copy".
    private static func build(_ binding: Binding, _ argument: String,
                              _ context: Context) -> VoiceCommand.Parsed? {
        guard let parsed = binding.build(argument, context) else { return nil }
        guard !argument.isEmpty, !isFiller(argument) else { return parsed }

        // If dropping the argument changes nothing, it was never read.
        guard let bare = binding.build("", context) else { return parsed }
        return encoded(bare.command) == encoded(parsed.command) ? nil : parsed
    }

    private static let fillerWords: Set<String> = [
        "please", "now", "thanks", "thank", "you", "for", "me", "it", "that", "this",
    ]

    private static func isFiller(_ argument: String) -> Bool {
        let words = argument.split(separator: " ").map(String.init)
        return words.count <= 3 && words.allSatisfy { fillerWords.contains($0) }
    }

    private static func encoded(_ command: Command) -> String {
        let encoder = JSONEncoder()
        // Without sortedKeys, two encodings of the same value can differ only
        // in key order, and comparing them would answer "different" at random.
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(command)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// Every capability, as canonical phrases. This doubles as the closed
    /// choice list handed to Jev: it can only ever pick something that really
    /// exists, and each choice may be a multi-step sequence.
    ///
    /// Takes the scope rather than reading it, for two reasons that were
    /// both measured: reading it here cost one osascript-backed `context()`
    /// call PER BINDING, and reading it here and again in `build(canonical:)`
    /// a model round-trip later meant the list was filtered under one scope
    /// and the chosen entry built under another.
    static func catalog(in explicitContext: Context? = nil) -> [String] {
        let context = explicitContext ?? self.context()
        return bindings.compactMap { binding in
            // Only argument-free capabilities: a classifier returns a label,
            // so it cannot supply a URL or a body of text.
            guard let phrase = binding.phrases.first,
                  binding.build("", context) != nil else { return nil }
            return phrase
        }
    }

    /// Build a capability chosen by its canonical phrase — in the same scope
    /// the catalogue was offered under, or the two can disagree.
    static func build(canonical: String, in explicitContext: Context? = nil) -> VoiceCommand.Parsed? {
        let context = explicitContext ?? self.context()
        for binding in bindings where binding.phrases.first == canonical {
            return binding.build("", context)
        }
        return nil
    }

    private static func keys(_ spec: String) -> Command { .pressKeys(spec: spec) }

    private static func step(_ label: String, _ steps: [Command]) -> VoiceCommand.Parsed {
        VoiceCommand.Parsed(command: .sequence(label: label, steps: steps), description: label)
    }

    /// Every phrase in the table, in table order, for the self-test that
    /// asserts no two bindings claim the same one.
    static var allPhrases: [String] { bindings.flatMap(\.phrases) }

    private static let bindings: [Binding] = [
        // MARK: Text editing
        Binding(phrases: ["select all", "select everything", "highlight all"]) { _, _ in
            step("Select all", [keys("cmd+a")])
        },
        Binding(phrases: ["delete all", "clear all", "clear it", "clear the field",
                          "delete everything", "clear search", "delete search term",
                          "clear the search", "erase all"]) { _, _ in
            // Select first, then delete: pressing delete alone removes one character.
            step("Clear the field", [keys("cmd+a"), keys("delete")])
        },
        Binding(phrases: ["copy"]) { _, _ in step("Copy", [keys("cmd+c")]) },
        Binding(phrases: ["paste"]) { _, _ in step("Paste", [keys("cmd+v")]) },
        Binding(phrases: ["cut"]) { _, _ in step("Cut", [keys("cmd+x")]) },
        Binding(phrases: ["undo"]) { _, _ in step("Undo", [keys("cmd+z")]) },
        Binding(phrases: ["redo"]) { _, _ in step("Redo", [keys("cmd+shift+z")]) },
        Binding(phrases: ["save"]) { _, _ in step("Save", [keys("cmd+s")]) },
        Binding(phrases: ["delete", "backspace"]) { _, _ in step("Delete", [keys("delete")]) },
        Binding(phrases: ["delete word", "delete the word"]) { _, _ in
            step("Delete word", [keys("option+delete")])
        },
        Binding(phrases: ["delete line", "delete the line"]) { _, _ in
            step("Delete line", [keys("cmd+delete")])
        },
        Binding(phrases: ["enter", "press enter", "return", "confirm", "submit"]) { _, _ in
            step("Enter", [keys("return")])
        },
        Binding(phrases: ["escape", "cancel", "dismiss", "close this", "click away", "tab away"]) { _, _ in
            step("Escape", [keys("escape")])
        },
        // "next field" belongs to the form binding further down, which
        // says "Next field" rather than "Tab" — the same keystroke, a
        // description that matches what you asked for. Claimed here as
        // well, which of the two answered was down to an unstable sort.
        Binding(phrases: ["tab"]) { _, _ in step("Tab", [keys("tab")]) },

        Binding(phrases: ["show me the form", "show the form", "fill the form",
                          "fill out the form", "show the login form", "show form",
                          "what are the fields", "fill this in"]) { _, _ in
            VoiceCommand.Parsed(command: .showForm,
                                description: "Show the form on your phone")
        },

        // MARK: Pointing — "this" and "here" mean wherever the pointer is
        //
        // The phone draws the pointer and lets you drag it, so aiming is a
        // gesture and the sentence stays short. Faster than numbering the
        // screen when you can already see what you want.
        Binding(phrases: ["enter password here", "enter the password here",
                          "type the password here", "enter my password",
                          "type password", "password here"]) { _, _ in
            // The password is typed on the phone. It never goes near the
            // microphone, a transcription service or the log.
            step("Ask the phone for the password", [
                .pointerAction(kind: "click"),
                .requestInput(field: "password", secret: true),
            ])
        },
        Binding(phrases: ["double click this", "double click here", "double click that",
                          "double click", "open this", "open that"]) { _, _ in
            VoiceCommand.Parsed(command: .pointerAction(kind: "double"),
                                description: "Double click the pointer")
        },
        Binding(phrases: ["right click this", "right click here", "right click that",
                          "context menu here", "context menu this"]) { _, _ in
            VoiceCommand.Parsed(command: .pointerAction(kind: "right"),
                                description: "Right click the pointer")
        },
        Binding(phrases: ["type here", "type in here", "write here", "enter text here",
                          "type something here", "let me type here"]) { _, _ in
            step("Ask the phone for text", [
                .pointerAction(kind: "click"),
                .requestInput(field: "text", secret: false),
            ])
        },
        Binding(phrases: ["click this", "click here", "click that", "press this",
                          "tap this", "tap here", "click it"]) { _, _ in
            VoiceCommand.Parsed(command: .pointerAction(kind: "click"),
                                description: "Click the pointer")
        },

        // MARK: Sound and media
        //
        // The explicit system phrases come first and are deliberately wordy:
        // they are the escape hatch for when you are on a page that redefines
        // the bare word and you meant the Mac after all.
        Binding(phrases: ["mute everything", "mute the mac", "mute the computer",
                          "mute system", "system mute", "mute all apps"]) { _, _ in
            VoiceCommand.Parsed(command: .systemAction(name: "mute", value: 0),
                                description: "Mute the Mac")
        },
        Binding(phrases: ["unmute everything", "unmute the mac", "unmute the computer",
                          "unmute system", "system unmute"]) { _, _ in
            VoiceCommand.Parsed(command: .systemAction(name: "unmute", value: 0),
                                description: "Unmute the Mac")
        },
        Binding(phrases: ["volume up", "turn it up", "louder", "increase volume",
                          "turn the volume up"]) { _, _ in
            VoiceCommand.Parsed(command: .systemAction(name: "volumeUp", value: 10),
                                description: "Volume up")
        },
        Binding(phrases: ["volume down", "turn it down", "quieter", "decrease volume",
                          "turn the volume down"]) { _, _ in
            VoiceCommand.Parsed(command: .systemAction(name: "volumeDown", value: 10),
                                description: "Volume down")
        },
        Binding(phrases: ["max volume", "full volume", "maximum volume", "volume all the way up"]) { _, _ in
            VoiceCommand.Parsed(command: .systemAction(name: "volumeSet", value: 100),
                                description: "Volume 100%")
        },
        Binding(phrases: ["no volume", "zero volume", "volume off", "silence"]) { _, _ in
            VoiceCommand.Parsed(command: .systemAction(name: "volumeSet", value: 0),
                                description: "Volume 0%")
        },
        Binding(phrases: ["set volume to", "volume"]) { argument, _ in
            // Whether "percent" was actually said, before it is stripped.
            // Without this, "set volume to 5 percent" took the tenths
            // path and produced 50% — an explicitly stated unit ignored,
            // on a request that is usually made to make something quiet.
            let saidPercent = argument.contains("percent") || argument.contains("%")
            let token = argument.replacingOccurrences(of: "percent", with: "")
                .replacingOccurrences(of: "%", with: "")
                .trimmingCharacters(in: .whitespaces)
            // One meaning per number, whichever way the recogniser wrote
            // it. A single digit was read as a percentage when it came
            // back as "5" and as a tenth when it came back as "five" —
            // so the same words gave 5% or 50% depending on a choice
            // nobody made, and Apple's recogniser prefers digits for
            // short numerics, which is the wrong one of the two.
            //
            // A bare single number means tenths, because "volume 5" is
            // how a person asks for half. "volume 50" is still 50.
            //
            // Keyed on the VALUE, not the token's length. Keying on
            // `token.count <= 2` looked right and could never be true
            // for a spelled digit — every one of them is at least three
            // characters — so "five" and "5" went on meaning different
            // things, merely swapped over from before.
            let spelled = spokenDigits[token]
            let written = Int(token)
            guard let raw = spelled ?? written else { return nil }
            let asked = (raw <= 10 && !saidPercent) ? raw * 10 : raw
            // Clamped, not refused. Returning nil here dropped the phrase
            // into the fuzzy matcher, which scored "volume up" against
            // "volume -5" within its edit budget — so asking for a
            // nonsense volume turned the volume UP. A number outside the
            // range is still unambiguously a volume request.
            let level = min(100, max(0, asked))
            return VoiceCommand.Parsed(command: .systemAction(name: "volumeSet", value: level),
                                       description: "Volume \(level)%")
        },
        Binding(phrases: ["mute", "mute the sound", "mute it"]) { _, _ in
            VoiceCommand.Parsed(command: .systemAction(name: "mute", value: 0), description: "Mute")
        },
        Binding(phrases: ["unmute", "unmute the sound", "sound on"]) { _, _ in
            VoiceCommand.Parsed(command: .systemAction(name: "unmute", value: 0), description: "Unmute")
        },
        Binding(phrases: ["play", "pause", "play pause", "resume"]) { _, _ in
            step("Play/pause", [keys("f8")])
        },
        Binding(phrases: ["next track", "next song", "skip", "skip song"]) { _, _ in
            step("Next track", [keys("f9")])
        },
        Binding(phrases: ["previous track", "previous song", "last song", "back a track"]) { _, _ in
            step("Previous track", [keys("f7")])
        },
        Binding(phrases: ["brighter", "brightness up", "increase brightness"]) { _, _ in
            VoiceCommand.Parsed(command: .systemAction(name: "brighter", value: 0), description: "Brighter")
        },
        Binding(phrases: ["dimmer", "brightness down", "decrease brightness", "darker screen"]) { _, _ in
            VoiceCommand.Parsed(command: .systemAction(name: "dimmer", value: 0), description: "Dimmer")
        },
        Binding(phrases: ["dark mode", "light mode", "toggle dark mode", "switch appearance"]) { _, _ in
            VoiceCommand.Parsed(command: .systemAction(name: "darkMode", value: 0),
                                description: "Switch appearance")
        },
        Binding(phrases: ["empty trash", "empty the trash", "take out the trash"]) { _, _ in
            VoiceCommand.Parsed(command: .systemAction(name: "emptyTrash", value: 0),
                                description: "Empty the trash")
        },

        // MARK: Desktop, spaces and windows
        Binding(phrases: ["show desktop", "reveal desktop", "toggle desktop", "hide everything"]) { _, _ in
            step("Show desktop", [keys("f11")])
        },
        Binding(phrases: ["mission control", "show all windows", "expose", "toggle mission control"]) { _, _ in
            step("Mission Control", [keys("f3")])
        },
        Binding(phrases: ["next window", "cycle windows", "other window"]) { _, _ in
            step("Next window", [keys("cmd+grave")])
        },
        Binding(phrases: ["previous window", "last window"]) { _, _ in
            step("Previous window", [keys("cmd+shift+grave")])
        },
        Binding(phrases: ["next space", "next desktop"]) { _, _ in
            step("Next space", [keys("ctrl+right")])
        },
        Binding(phrases: ["previous space", "last space", "previous desktop"]) { _, _ in
            step("Previous space", [keys("ctrl+left")])
        },
        Binding(phrases: ["full screen", "fullscreen", "maximise", "maximize"]) { _, _ in
            step("Full screen", [keys("cmd+ctrl+f")])
        },
        Binding(phrases: ["hide app", "hide this app", "hide this"]) { _, _ in
            step("Hide", [keys("cmd+h")])
        },
        Binding(phrases: ["lock screen", "lock the mac", "lock it"]) { _, _ in
            step("Lock screen", [keys("ctrl+cmd+q")])
        },
        Binding(phrases: ["screenshot", "take a screenshot", "capture screen"]) { _, _ in
            step("Screenshot", [keys("cmd+shift+5")])
        },

        // MARK: Zoom and find
        Binding(phrases: ["zoom in", "bigger", "enlarge"]) { _, _ in step("Zoom in", [keys("cmd+equal")]) },
        Binding(phrases: ["zoom out", "smaller", "shrink"]) { _, _ in step("Zoom out", [keys("cmd+minus")]) },
        Binding(phrases: ["reset zoom", "actual size", "normal zoom"]) { _, _ in
            step("Reset zoom", [keys("cmd+0")])
        },
        Binding(phrases: ["find next", "next result", "next match"]) { _, _ in
            step("Find next", [keys("cmd+g")])
        },
        Binding(phrases: ["find previous", "previous result", "previous match"]) { _, _ in
            step("Find previous", [keys("cmd+shift+g")])
        },
        Binding(phrases: ["bookmark this", "bookmark page", "save bookmark"]) { _, _ in
            step("Bookmark", [keys("cmd+d")])
        },
        Binding(phrases: ["developer tools", "dev tools", "inspector", "inspect"]) { _, _ in
            step("Developer tools", [keys("cmd+option+i")])
        },
        Binding(phrases: ["toggle hidden files", "show hidden files", "hide hidden files"]) { _, _ in
            step("Toggle hidden files", [keys("cmd+shift+period")])
        },


        // MARK: Jumping to the ends
        Binding(phrases: ["scroll to the bottom", "scroll to bottom", "go to the bottom",
                          "jump to the bottom", "bottom of the page", "go to the end",
                          "scroll all the way down"]) { _, _ in
            // Command+Down is end-of-document across Cocoa and the browsers;
            // a very large scroll would stop at whatever is currently loaded.
            step("Bottom", [keys("cmd+down")])
        },
        Binding(phrases: ["scroll to the top", "scroll to top", "go to the top",
                          "jump to the top", "top of the page", "go to the beginning",
                          "scroll all the way up"]) { _, _ in
            step("Top", [keys("cmd+up")])
        },
        Binding(phrases: ["end of line", "go to end of line"]) { _, _ in
            step("End of line", [keys("cmd+right")])
        },
        Binding(phrases: ["start of line", "beginning of line", "go to start of line"]) { _, _ in
            step("Start of line", [keys("cmd+left")])
        },

        // MARK: Browser and Electron navigation
        Binding(phrases: ["new tab", "open a new tab"]) { _, _ in step("New tab", [keys("cmd+t")]) },
        Binding(phrases: ["close all tabs", "close every tab", "close all the tabs",
                          "shut all tabs"]) { _, _ in
            // cmd+shift+w closes the window and with it every tab. cmd+w only
            // ever closes the one in front, which is why "close all tabs" did
            // nothing useful.
            step("Close all tabs", [keys("cmd+shift+w")])
        },
        Binding(phrases: ["close other tabs", "close the other tabs"]) { _, _ in
            step("Close other tabs", [keys("cmd+option+w")])
        },
        Binding(phrases: ["close tab", "close the tab"]) { _, _ in step("Close tab", [keys("cmd+w")]) },
        Binding(phrases: ["reopen tab", "undo close tab", "restore tab"]) { _, _ in
            step("Reopen closed tab", [keys("cmd+shift+t")])
        },
        Binding(phrases: ["next tab", "go to next tab"]) { _, _ in
            step("Next tab", [keys("ctrl+tab")])
        },
        Binding(phrases: ["previous tab", "prior tab", "go to previous tab", "last tab"]) { _, _ in
            step("Previous tab", [keys("ctrl+shift+tab")])
        },
        Binding(phrases: ["go back", "back", "navigate back"]) { _, _ in
            step("Back", [keys("cmd+left")])
        },
        Binding(phrases: ["go forward", "forward", "navigate forward"]) { _, _ in
            step("Forward", [keys("cmd+right")])
        },
        Binding(phrases: ["reload", "refresh", "reload the page", "refresh the page"]) { _, _ in
            step("Reload", [keys("cmd+r")])
        },
        Binding(phrases: ["hard reload", "force reload"]) { _, _ in
            step("Hard reload", [keys("cmd+shift+r")])
        },
        Binding(phrases: ["focus the address bar", "focus address bar", "focus the url bar",
                          "focus search", "focus the search bar", "focus search bar"]) { _, context in
            step("Focus the address bar", [keys(context.isBrowserLike ? "cmd+l" : "cmd+f")])
        },
        Binding(phrases: ["find", "search the page", "find on page"]) { argument, _ in
            argument.isEmpty
                ? step("Find", [keys("cmd+f")])
                : step("Find “\(argument)”", [keys("cmd+f"), keys("cmd+a"),
                                              .typeText(text: argument), keys("return")])
        },
        Binding(phrases: ["go to tab", "switch to tab", "tab number"]) { argument, _ in
            guard let index = digit(argument), (1...9).contains(index) else { return nil }
            return step("Go to tab \(index)", [keys("cmd+\(index)")])
        },
        Binding(phrases: ["go to", "browse", "browse to", "open the website", "navigate to",
                          "visit", "open site", "open website"]) { argument, context in
            guard !argument.isEmpty, context.isBrowserLike || looksLikeURL(argument),
                  namesADestination(argument) else { return nil }
            guard let destination = normalisedDestination(argument) else { return nil }
            // Hand the URL to the system rather than typing it. The keystroke
            // version opened a tab and then reliably failed to enter anything,
            // because a freshly focused address bar does not accept synthetic
            // unicode events. This just works, and opens a new tab anyway.
            return VoiceCommand.Parsed(command: .openURL(url: "https://" + destination),
                                       description: "Open \(destination)")
        },

        // MARK: Windows and system
        Binding(phrases: ["close window"]) { _, _ in step("Close window", [keys("cmd+w")]) },
        Binding(phrases: ["quit this", "quit this app", "quit the app"]) { _, context in
            step("Quit \(context.appName)", [keys("cmd+q")])
        },
        Binding(phrases: ["minimise", "minimize"]) { _, _ in step("Minimise", [keys("cmd+m")]) },
        Binding(phrases: ["switch app", "next app", "app switcher"]) { _, _ in
            step("Switch app", [keys("cmd+tab")])
        },
        Binding(phrases: ["new window"]) { _, _ in step("New window", [keys("cmd+shift+n")]) },
        Binding(phrases: ["spotlight", "open spotlight"]) { _, _ in
            step("Spotlight", [keys("cmd+space")])
        },

        // MARK: Documents and notes
        Binding(phrases: ["new note", "create a note", "create new note", "add a note",
                          "new note called", "create a new note"]) { argument, _ in
            // Activate Notes first. Sending cmd+n to whatever happens to be in
            // front opened a Safari window and reported "New note in Safari".
            var steps: [Command] = [.launchApp(bundleIdentifier: "com.apple.Notes"), keys("cmd+n")]
            if !argument.isEmpty { steps.append(.typeText(text: argument)) }
            return step(argument.isEmpty ? "New note" : "New note “\(argument)”", steps)
        },
        Binding(phrases: ["search notes", "find a note", "search my notes"]) { argument, _ in
            var steps: [Command] = [.launchApp(bundleIdentifier: "com.apple.Notes"),
                                    keys("cmd+option+f")]
            if !argument.isEmpty { steps += [.typeText(text: argument), keys("return")] }
            return step(argument.isEmpty ? "Search Notes" : "Search Notes for “\(argument)”", steps)
        },
        Binding(phrases: ["new email", "new message", "compose email", "write an email"]) { argument, _ in
            var steps: [Command] = [.launchApp(bundleIdentifier: "com.apple.mail"), keys("cmd+n")]
            if !argument.isEmpty { steps.append(.typeText(text: argument)) }
            return step("New email", steps)
        },
        Binding(phrases: ["search mail", "search email", "find an email"]) { argument, _ in
            var steps: [Command] = [.launchApp(bundleIdentifier: "com.apple.mail"), keys("cmd+option+f")]
            if !argument.isEmpty { steps += [.typeText(text: argument), keys("return")] }
            return step("Search Mail", steps)
        },
        // NOT "search notes" — the Notes binding above owns that, and
        // both claimed it. Matching orders by the length of a binding's
        // FIRST phrase, both first phrases were "search notes", and
        // `sorted(by:)` is not documented to be stable, so "search notes
        // shopping" either searched Notes or pressed cmd+L in the
        // browser and sent the words to a search engine. Which one was
        // down to the sort.
        Binding(phrases: ["search for", "search"]) { argument, context in
            var steps: [Command] = [keys(context.isBrowserLike ? "cmd+l" : "cmd+f"), keys("cmd+a")]
            if !argument.isEmpty {
                steps.append(.typeText(text: argument))
                steps.append(keys("return"))
            }
            return step(argument.isEmpty ? "Search in \(context.appName)"
                                         : "Search for “\(argument)”", steps)
        },
        Binding(phrases: ["show numbers", "show number", "numbers", "show guide",
                          "show guides", "number things", "label things",
                          "which is which", "show labels"]) { _, _ in
            step("Numbers on screen", [.showNumbers(on: true)])
        },
        Binding(phrases: ["hide numbers", "hide guide", "hide guides", "hide labels"]) { _, _ in
            step("Numbers off", [.showNumbers(on: false)])
        },
        Binding(phrases: ["type", "write", "enter text", "say"]) { argument, _ in
            guard !argument.isEmpty else { return nil }
            return step("Type “\(argument)”", [.typeText(text: argument)])
        },
        // MARK: Forms and credentials
        Binding(phrases: ["autofill", "autofill password", "fill password",
                          "use saved password", "fill my password"]) { _, _ in
            // Let the password manager do it. Nothing secret passes through
            // jev at all, which is the safest possible arrangement.
            step("Autofill from Passwords", [keys("cmd+backslash")])
        },
        Binding(phrases: ["fill"]) { argument, _ in
            // "fill email with me@example.com"
            guard let range = argument.range(of: " with ") else { return nil }
            let field = String(argument[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let value = String(argument[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !field.isEmpty, !value.isEmpty else { return nil }
            return VoiceCommand.Parsed(command: .fillField(label: field, text: value),
                                       description: "Fill “\(field)”")
        },
        Binding(phrases: ["next field", "tab to next field"]) { _, _ in
            step("Next field", [keys("tab")])
        },
        Binding(phrases: ["previous field", "back a field"]) { _, _ in
            step("Previous field", [keys("shift+tab")])
        },
        Binding(phrases: ["log in", "login", "sign in", "log in to", "sign in to"]) { argument, context in
            // Deliberately does NOT handle the password. It focuses the form
            // and invokes the system password manager; anything secret comes
            // from Passwords or from you typing it on the phone.
            var steps: [Command] = []
            if !argument.isEmpty {
                // Refuses rather than guesses. "sign in to my bank and check the
                // balance" reached here with no guard and became a domain.
                guard let host = normalisedDestination(argument) else { return nil }
                steps.append(.openURL(url: "https://" + host))
            }
            steps.append(keys("cmd+backslash"))
            return step(argument.isEmpty ? "Autofill this login" : "Open \(argument) and autofill",
                        steps)
        },

        // MARK: Spreadsheets
        Binding(phrases: ["go to cell", "select cell", "cell"]) { argument, _ in
            let reference = argument.replacingOccurrences(of: " ", with: "").uppercased()
            guard !reference.isEmpty else { return nil }
            // The name box: ctrl+G in Excel, and Numbers accepts the same jump.
            return step("Go to cell \(reference)",
                        [keys("ctrl+g"), .typeText(text: reference), keys("return")])
        },
        Binding(phrases: ["next cell", "move right"]) { _, _ in step("Next cell", [keys("tab")]) },
        Binding(phrases: ["cell below", "move down"]) { _, _ in step("Cell below", [keys("down")]) },
        Binding(phrases: ["cell above", "move up"]) { _, _ in step("Cell above", [keys("up")]) },
        Binding(phrases: ["new row", "insert row"]) { _, _ in
            step("Insert row", [keys("ctrl+shift+equal")])
        },
        Binding(phrases: ["bold"]) { _, _ in step("Bold", [keys("cmd+b")]) },
        Binding(phrases: ["italic"]) { _, _ in step("Italic", [keys("cmd+i")]) },
        Binding(phrases: ["underline"]) { _, _ in step("Underline", [keys("cmd+u")]) },
        Binding(phrases: ["print"]) { _, _ in step("Print", [keys("cmd+p")]) },
        Binding(phrases: ["select row"]) { _, _ in step("Select row", [keys("shift+space")]) },
        Binding(phrases: ["select column"]) { _, _ in step("Select column", [keys("ctrl+space")]) },

        Binding(phrases: ["right click on", "right click", "secondary click on", "context menu on"]) { argument, _ in
            guard !argument.isEmpty else { return nil }
            return VoiceCommand.Parsed(command: .rightClickControl(label: argument),
                                       description: "Right click “\(argument)”")
        },
    ]

    // MARK: Helpers

    private static let spokenDigits = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        // Both ends of the volume range as people actually say them.
        // "volume ten" matched nothing while "volume 10" was 100%.
        "half": 5, "full": 10,
    ]

    private static func digit(_ text: String) -> Int? {
        let token = text.split(separator: " ").first.map(String.init) ?? text
        return Int(token) ?? spokenDigits[token]
    }

    private static func looksLikeURL(_ text: String) -> Bool {
        // " dot " counts. Speech writes an address that way, and without it
        // "go to github dot com" was only recognised as an address when a
        // browser happened to be frontmost — the same sentence meant
        // different things depending on what was in front of it.
        text.contains(".") || text.hasPrefix("http") || text.contains(" dot ")
    }

    /// Whether "go to X" is naming a place this code can be *sure* about.
    ///
    /// Not "is this probably a domain". `normalisedDestination` removes every
    /// space and appends ".com", so a wrong answer here does not degrade — it
    /// invents an address out of someone's words and opens it. Three real
    /// ones, all said aloud:
    ///
    ///     "go to YouTube and search hello"     -> youtubeandsearchhello.com
    ///     "go to youtube dot com and search …" -> youtube.comandsearchhellboy
    ///     "go to workspace three"              -> workspacethree.com
    ///
    /// Each was fixed by making the guess cleverer, and the next phrasing
    /// broke it again. The guess is the bug. jev has a classifier that
    /// decides open_url against web_task against everything else, measured at
    /// 0.98 and above on exactly these sentences — so anything this function
    /// is not certain about is now its problem, not this one's.
    ///
    /// What stays here is what needs no judgement: an address, or a site
    /// named in a list this code owns. Those are instant and work offline,
    /// which is the whole reason the phrasebook runs first. Everything else
    /// declines and costs one model call, which is the right price for not
    /// opening a domain nobody asked for.
    static func namesADestination(_ raw: String) -> Bool {
        let text = raw.lowercased().trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return false }

        let words = Set(text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))

        // Two instructions, not one place. Whole words, so "playstation" is
        // not "play" and "searchencrypt" is not "search".
        let taskVerbs: Set<String> = [
            "search", "searching", "find", "play", "watch", "buy", "order",
            "click", "press", "type", "scroll", "download", "post", "reply",
            "send", "share", "subscribe", "follow", "like", "add", "checkout",
        ]
        if !words.isDisjoint(with: taskVerbs) { return false }
        if words.contains("then") { return false }

        // Something more specific already understands this sentence. There is
        // a parser for "go to workspace 3", spoken digits and all, that never
        // ran because this binding claimed the words first.
        if VoiceCommand.workspaceId(in: text) != nil { return false }

        // An address, written or spoken. No judgement required.
        if text.contains(".") || text.hasPrefix("http") || text.contains(" dot ") { return true }

        // A site this code already knows by name — the same list a web task
        // starts from, so "go to youtube" and "play something on youtube"
        // agree about where youtube is.
        let bare = words.subtracting(["to", "the", "my", "a", "an"]).joined(separator: " ")
        let spoken = text.replacingOccurrences(of: "^(to|the|my) ", with: "",
                                               options: .regularExpression)
        for site in WebStart.knownSites
        where site.spoken == spoken || site.spoken == bare
            || site.spoken.replacingOccurrences(of: " ", with: "") == bare {
            return true
        }

        // Anything else is a guess, and guesses belong to the classifier.
        return false
    }

    /// Speech writes "facebook.com" as "facebook dot com", and a bare word is
    /// a search rather than a host.
    /// Turn a whole spoken sentence into a destination, for the resolver.
    ///
    /// The model decides *whether* something is a place; this turns the
    /// person's own words into the address. Keeping the two apart is the
    /// point: a model that answered with a URL would be producing something
    /// executable, which is the freedom withheld from it everywhere else. It
    /// answers yes or no, and the words were the person's already.
    static func destination(fromSpoken sentence: String) -> String? {
        var text = sentence.lowercased().trimmingCharacters(in: .whitespaces)
        let leads = ["go to", "browse to", "browse", "navigate to", "visit",
                     "open the website", "open website", "open site", "open"]
        // The bare verb with nothing after it is not a destination. Without
        // this, "go to" — someone stopping mid-sentence — became `goto.com`,
        // because the prefix only matched with a trailing space.
        if leads.contains(text) { return nil }
        for lead in leads where text.hasPrefix(lead + " ") {
            text = String(text.dropFirst(lead.count + 1))
            break
        }
        // "…website" and "…page" are how people name a site aloud; they are
        // not part of the host.
        for tail in [" website", " site", " page", " dot com website"]
        where text.hasSuffix(tail) {
            text = String(text.dropLast(tail.count))
            break
        }
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return normalisedDestination(text)
    }

    /// Turn spoken words into a host, or refuse.
    ///
    /// This used to be a total function: it deleted every space, appended
    /// ".com" to anything without a dot, and returned a `String`. There was
    /// no way out of it that meant "that was not a place", so the whole
    /// burden of correctness sat on a word list in front of it — and every
    /// phrasing not on the list became a domain and opened:
    ///
    ///     "youtube and search hello"           -> youtubeandsearchhello.com
    ///     "youtube dot com and search hellboy" -> youtube.comandsearchhellboy
    ///     "workspace three"                    -> workspacethree.com
    ///
    /// Now it returns nil, and one rule does the work the list was doing. If
    /// the person said a dot, nothing may follow the final label — "bath and
    /// body works dot com" is one host, "youtube dot com and search hellboy"
    /// is a host and then a task. If they said no dot, it must be a single
    /// word: "facebook" is a guess worth making, "workspace three" is not.
    /// A name in `WebStart.knownSites` resolves to its real address instead
    /// of a guess, which is how "stack overflow" reaches stackoverflow.com.
    static func normalisedDestination(_ raw: String) -> String? {
        var text = raw.lowercased().trimmingCharacters(in: .whitespaces)
        // "log in to facebook" must not become the host "to facebook". "the"
        // is deliberately not here: it is part of the name at theverge.com
        // and theguardian.com, and dropping it produced the wrong sites.
        for filler in ["to ", "my "] where text.hasPrefix(filler) {
            text = String(text.dropFirst(filler.count))
        }
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        // A site this code already knows: its real address, not a guess.
        if let site = WebStart.knownSites.first(where: { $0.spoken == text }),
           let host = URL(string: site.url)?.host {
            return host
        }

        // Something typed or pasted rather than spoken.
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) {
            text = String(text.dropFirst(scheme.count))
        }

        // Host and path part company at the first slash, spoken or written.
        let spokenSlash = text.replacingOccurrences(of: " slash ", with: "/")
        let pieces = spokenSlash.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        var host = String(pieces[0]).replacingOccurrences(of: " dot ", with: ".")
            .trimmingCharacters(in: .whitespaces)
        let path = pieces.count > 1 ? String(pieces[1]) : ""

        if let lastDot = host.lastIndex(of: ".") {
            // Words after the final label are a task, not part of the host.
            guard !host[host.index(after: lastDot)...].contains(" ") else { return nil }
            host = host.replacingOccurrences(of: " ", with: "")
        } else {
            // No dot: only a single word is a guess worth making.
            guard !host.contains(" ") else { return nil }
            host += ".com"
        }

        // What can actually be a host. Anything else was never an address.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              labels.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasSuffix("-") })
        else { return nil }

        // A path with spaces in it is not something anyone spelled out.
        guard !path.contains(" ") else { return nil }
        return path.isEmpty ? host : host + "/" + path
    }
}
