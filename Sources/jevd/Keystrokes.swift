import Foundation
import AppKit
import JevCore

/// Synthesise keyboard shortcuts: "cmd+q", "option+1", "escape", "ctrl+shift+tab".
///
/// This is the general escape hatch. Anything a Mac app can be driven with from
/// the keyboard becomes reachable, including things with no accessibility
/// affordance at all. It cannot touch a TCC consent sheet — macOS ignores
/// synthetic input there by design, and no amount of key posting changes that.
enum Keystrokes {
    /// Virtual key codes are positional, not alphabetical, so they have to be
    /// spelled out rather than computed.
    private static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
        "escape": 53, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "f13": 105, "f14": 107, "f15": 113, "f16": 106,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "minus": 27, "equal": 24, "comma": 43, "period": 47, "slash": 44,
        "backslash": 42, "semicolon": 41, "quote": 39, "grave": 50,
        "leftbracket": 33, "rightbracket": 30,
        // The punctuation as it is actually typed, not only spelled out.
        // "cmd+-" is how a person writes zoom-out, and the parser splits
        // it to ["cmd", "-"], which matched nothing — so the previous fix
        // to the hyphen parsing moved the error message and left the
        // command just as broken.
        "-": 27, "=": 24, ",": 43, ".": 47, "/": 44,
        "\\": 42, ";": 41, "'": 39, "`": 50, "[": 33, "]": 30,
        "plus": 24, "dash": 27, "hyphen": 27,
    ]

    private static let modifiers: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand, "⌘": .maskCommand,
        "opt": .maskAlternate, "option": .maskAlternate, "alt": .maskAlternate, "⌥": .maskAlternate,
        "ctrl": .maskControl, "control": .maskControl, "⌃": .maskControl,
        "shift": .maskShift, "⇧": .maskShift,
        "fn": .maskSecondaryFn,
    ]

    static func press(_ spec: String) -> ExecutionResult {
        // Trimmed FIRST. The separator rule below consults the spec, and
        // testing an untrimmed one against a trimmed split meant a single
        // trailing space flipped the rule and silently ate the key:
        // "cmd+- " failed with `Unknown key "cmd"`.
        let spec = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalised = spec.lowercased().replacingOccurrences(of: " plus ", with: "+")

        // A hyphen separates unless it IS the key.
        //
        // Two earlier spellings of this rule were both wrong. The first,
        // `$0 == "+" || $0 == "-" && spec.contains("+")`, binds as
        // `"+" || ("-" && …)` and made `cmd-q` fail outright. The
        // second keyed on "does the whole spec end in -", which disabled
        // hyphen-splitting for the ENTIRE spec, so `cmd--` collapsed to
        // one token. Written out as statements this time, because the
        // one-expression versions are what kept hiding the mistake.
        let endsInHyphen = normalised.hasSuffix("-")
        let splittable = endsInHyphen ? String(normalised.dropLast()) : normalised
        var parts = splittable
            .split(whereSeparator: { $0 == "+" || $0 == "-" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if endsInHyphen { parts.append("-") }

        guard let keyName = parts.last else {
            return .failed(reason: "No key in “\(spec)”")
        }
        guard let keyCode = keyCodes[keyName] else {
            return .failed(reason: "Unknown key “\(keyName)”")
        }

        var flags: CGEventFlags = []
        for modifier in parts.dropLast() {
            guard let flag = modifiers[modifier] else {
                return .failed(reason: "Unknown modifier “\(modifier)”")
            }
            flags.insert(flag)
        }

        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return .failed(reason: "Could not synthesise the keystroke")
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return .ok(reason: "Pressed \(spec)")
    }

    /// Turn spoken phrasing into a spec: "press command q" -> "command+q".
    static func specFromSpokenPhrase(_ text: String) -> String? {
        let lowered = text.lowercased()
        for verb in ["press ", "hit ", "key ", "send key "] where lowered.hasPrefix(verb) {
            var rest = String(lowered.dropFirst(verb.count))
            for filler in ["the ", "keys ", "key "] where rest.hasPrefix(filler) {
                rest = String(rest.dropFirst(filler.count))
            }
            let tokens = rest.split(whereSeparator: { $0 == " " || $0 == "+" })
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".!?,")) }
                .filter { !$0.isEmpty && $0 != "and" }
            guard !tokens.isEmpty else { return nil }
            // Every token must be a modifier or a key, otherwise this was not
            // a keyboard request at all and should fall through to Jev.
            for token in tokens.dropLast() where modifiers[token] == nil { return nil }
            guard keyCodes[tokens[tokens.count - 1]] != nil else { return nil }
            return tokens.joined(separator: "+")
        }
        return nil
    }
}
