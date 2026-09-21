import Foundation
import CoreGraphics

/// The translation between how macOS numbers keys and how USB does.
///
/// `Keystrokes` addresses keys by macOS virtual keycode — `a` is 0, `return` is
/// 36 — because that is what `CGEvent` wants. A USB keyboard reports HID usage
/// IDs, where `a` is 4 and `return` is 40. The two numbering systems agree on
/// nothing, and until this file existed the board could be told to press a key
/// and had no way to be told *which* key. That is why `HIDBridge.key` had no
/// callers.
///
/// It matters beyond tidiness. A password field turns on secure input, which
/// makes macOS discard keystrokes made by software — and cannot discard a real
/// keyboard, or you could not type your own password. So a keychain prompt is
/// answerable from the phone only through the board, and only through here.
///
/// ## The one thing to know
///
/// **HID usages are positional.** Usage 4 means "the key where A sits on a US
/// keyboard", not the letter A. On AZERTY the same usage types `q`. Everything
/// here is therefore correct for US/ABC layouts and wrong for others, which is
/// checked at the point of use rather than hidden — see `looksLikeUSLayout`.
enum HIDKeycodes {

    // MARK: - Modifiers

    /// The HID modifier byte, as the firmware's `KEY <modifier> <codes>` wants.
    static let control: UInt8 = 0x01
    static let shift: UInt8 = 0x02
    static let option: UInt8 = 0x04
    static let command: UInt8 = 0x08

    /// macOS event flags → the HID modifier byte.
    ///
    /// Nil when a flag has no USB equivalent, so the caller refuses rather than
    /// quietly pressing the key without it. `fn` is the case that matters: it
    /// is a hardware key on an Apple keyboard, not a HID modifier, and sending
    /// `fn+left` as plain `left` would move the cursor one character instead of
    /// to the start of the line.
    static func modifier(from flags: CGEventFlags) -> UInt8? {
        if flags.contains(.maskSecondaryFn) { return nil }
        var byte: UInt8 = 0
        if flags.contains(.maskControl) { byte |= control }
        if flags.contains(.maskShift) { byte |= shift }
        if flags.contains(.maskAlternate) { byte |= option }
        if flags.contains(.maskCommand) { byte |= command }
        return byte
    }

    // MARK: - Keys

    /// macOS virtual keycode → USB HID usage.
    ///
    /// Keyed on the keycode rather than the name, so the aliases `Keystrokes`
    /// accepts — `return`/`enter`, `-`/`minus`/`dash` — collapse to one entry
    /// and cannot drift apart. Every value in `Keystrokes.keyCodes` appears
    /// here; a launch assertion proves it.
    static let usage: [CGKeyCode: UInt8] = [
        // Letters, in macOS's order, which is not alphabetical.
        0: 4, 1: 22, 2: 7, 3: 9, 4: 11, 5: 10, 6: 29, 7: 27, 8: 6, 9: 25,
        11: 5, 12: 20, 13: 26, 14: 8, 15: 21, 16: 28, 17: 23,
        31: 18, 32: 24, 34: 12, 35: 19, 37: 15, 38: 13, 40: 14, 45: 17, 46: 16,

        // The number row. Note macOS puts 6 before 5.
        18: 30, 19: 31, 20: 32, 21: 33, 23: 34, 22: 35, 26: 36, 28: 37, 25: 38, 29: 39,

        // The keys with names.
        36: 40,   // return
        53: 41,   // escape
        51: 42,   // delete / backspace
        48: 43,   // tab
        49: 44,   // space

        // Punctuation.
        27: 45,   // -
        24: 46,   // =
        33: 47,   // [
        30: 48,   // ]
        42: 49,   // \
        41: 51,   // ;
        39: 52,   // '
        50: 53,   // `
        43: 54,   // ,
        47: 55,   // .
        44: 56,   // /

        // Function keys.
        122: 58, 120: 59, 99: 60, 118: 61, 96: 62, 97: 63,
        98: 64, 100: 65, 101: 66, 109: 67, 103: 68, 111: 69,
        105: 104, 107: 105, 113: 106, 106: 107,

        // Navigation.
        115: 74,  // home
        116: 75,  // page up
        119: 77,  // end
        121: 78,  // page down
        124: 79,  // right
        123: 80,  // left
        125: 81,  // down
        126: 82,  // up
    ]

    // MARK: - Characters

    /// Printable ASCII → the key to press, and whether shift is held.
    ///
    /// Typing a password is a sequence of these. Anything not here returns nil
    /// and the caller refuses: typing an approximation of someone's password is
    /// worse than typing nothing, because it looks like it worked.
    static func character(_ character: Character) -> (shift: Bool, usage: UInt8)? {
        if let plain = unshifted[character] { return (false, plain) }
        if let shifted = Self.shifted[character] { return (true, shifted) }
        return nil
    }

    /// Built once from the rows below rather than written out twice, because a
    /// hand-typed second copy is where the wrong letter comes from.
    private static let unshifted: [Character: UInt8] = {
        var table: [Character: UInt8] = [:]
        for (offset, letter) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
            table[letter] = UInt8(4 + offset)
        }
        for (offset, digit) in "1234567890".enumerated() {
            table[digit] = UInt8(30 + offset)
        }
        for (character, code) in zip("-=[]\\;'`,./", [45, 46, 47, 48, 49, 51, 52, 53, 54, 55, 56]) {
            table[character] = UInt8(code)
        }
        table[" "] = 44
        table["\n"] = 40
        table["\t"] = 43
        return table
    }()

    private static let shifted: [Character: UInt8] = {
        var table: [Character: UInt8] = [:]
        for (offset, letter) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() {
            table[letter] = UInt8(4 + offset)
        }
        // The number row, shifted, in the order the digits sit on the keyboard.
        for (offset, symbol) in "!@#$%^&*()".enumerated() {
            table[symbol] = UInt8(30 + offset)
        }
        for (character, code) in zip("_+{}|:\"~<>?", [45, 46, 47, 48, 49, 51, 52, 53, 54, 55, 56]) {
            table[character] = UInt8(code)
        }
        return table
    }()

    // MARK: - The layout caveat

    /// Whether the active input source is one these positional usages are
    /// correct for.
    ///
    /// Asked rather than assumed, because the failure is silent and expensive:
    /// on a French layout, sending the usage for "the A key" types `q`, so a
    /// password would be typed wrong with no error anywhere. Callers warn once.
    static func looksLikeUSLayout(_ identifier: String?) -> Bool {
        guard let identifier = identifier?.lowercased() else { return false }
        // The layouts that share the US positions for letters and digits.
        return identifier.hasSuffix(".us") || identifier.hasSuffix(".abc")
            || identifier.contains("abc-") || identifier.hasSuffix(".australian")
            || identifier.hasSuffix(".british") || identifier.hasSuffix(".canadian")
            || identifier.hasSuffix(".irish")
    }
}
