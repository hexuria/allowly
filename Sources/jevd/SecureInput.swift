import Foundation
import Carbon.HIToolbox

/// Whether macOS is currently refusing keystrokes made by software.
///
/// A password field turns this on for the whole system. While it is on, a
/// `CGEvent` keystroke is discarded — not rejected, not reported, simply gone.
/// Nothing in Allowly checked for it, so typing into a password box "succeeded"
/// every time and nothing happened, which is the worst shape a failure can
/// take: it looks like the feature works and you are the one getting it wrong.
///
/// It cannot block a real keyboard. That is not a loophole, it is the point —
/// otherwise you could not type your own password. So the board works here and
/// software does not, and this exists to tell the difference out loud.
enum SecureInput {

    static var isOn: Bool { IsSecureEventInputEnabled() }

    static let explanation =
        "Something on your Mac is asking for a password, so macOS is ignoring "
        + "typing that comes from software. Plug in the USB board and this works, "
        + "or type it at the Mac."

    /// The keyboard layout the board's key numbers assume.
    ///
    /// HID usages are positional: the board says "the key where A sits", and
    /// macOS turns that into a letter using the active layout. On AZERTY that
    /// key is `q`, so a password would be typed wrong with nothing anywhere
    /// saying so. Read here so a caller can say it once.
    static var currentLayoutIdentifier: String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
            return nil
        }
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    /// Say it once per launch, not once per keystroke.
    nonisolated(unsafe) private static var warnedAboutLayout = false

    /// Warn if the board's positional key numbers will not produce the
    /// characters we mean on this Mac.
    static func warnIfLayoutIsNotUS(log: (String) -> Void) {
        guard !warnedAboutLayout else { return }
        let identifier = currentLayoutIdentifier
        guard !HIDKeycodes.looksLikeUSLayout(identifier) else { return }
        warnedAboutLayout = true
        log("[allowly] keyboard layout is \(identifier ?? "unknown"); the USB board sends key "
            + "POSITIONS, so typed characters may not match. Letters and digits are only "
            + "guaranteed on a US/ABC layout.")
    }
}
