import Foundation
import JevCore
import JevCapture

/// Did the command actually do anything?
///
/// A keystroke command reports `ok` the instant it is posted. Whether the Mac
/// acted on it is a different question, and nothing was asking it — so
/// `close tab` firing about one time in three looked exactly like it working
/// every time, and the only way to find out was to count tabs by hand.
///
/// The check is deliberately dumb and general: take a small, cheap
/// fingerprint of the screen before and after, and see whether anything
/// moved. It cannot say *what* happened, and it does not try. It answers the
/// only question that was previously unanswerable — "did the screen change at
/// all?" — which is enough to tell a command that worked from one that
/// vanished.
///
/// What it deliberately does not do:
///
///   * block or slow the command — the "before" frame is taken while the
///     command runs, not before it;
///   * decide anything. It writes a word into the journal. Nothing branches
///     on it, because a false negative must never turn a successful action
///     into a reported failure.
enum EffectCheck {

    /// What the screen looked like, small enough to be cheap to compare.
    ///
    /// A downscaled JPEG already exists for the phone, so this reuses that
    /// path rather than adding a second capture stack. The byte count and a
    /// coarse hash together are plenty: a closed tab, a moved window or a
    /// pressed button all change them; a still screen does not.
    struct Fingerprint: Sendable, Equatable {
        let bytes: Int
        let hash: Int
    }

    static func sample() async -> Fingerprint? {
        // Small on purpose. This is a change detector, not a screenshot.
        // Without the cursor, and a little larger than a thumbnail: at 320px
        // a typed character or a toggled checkbox can round away inside one
        // JPEG block and read as "nothing happened".
        guard let data = await ScreenCapturer.shared.captureDisplay(
            maxDimension: 640, quality: 0.5, showsCursor: false) else { return nil }
        var hash = 5381
        // Every 7th byte: enough to catch a repaint, cheap on a 20 KB frame.
        // Strided from startIndex, not from zero — a Data slice does not
        // begin at 0 and indexing one by offset traps, which inside a
        // detached task would take the daemon down.
        for index in stride(from: data.startIndex, to: data.endIndex, by: 7) {
            hash = (hash &* 33) ^ Int(data[index])
        }
        return Fingerprint(bytes: data.count, hash: hash)
    }

    /// Compare two samples taken either side of a command.
    ///
    /// Returns the word that goes in the journal. Nil when the check could
    /// not be made at all, which is not the same as "nothing happened" and
    /// must not be recorded as if it were.
    static func verdict(before: Fingerprint?, after: Fingerprint?) -> String? {
        guard let before, let after else { return nil }
        if before == after { return "no-change" }
        return "changed"
    }

    /// What the verdict does NOT mean.
    ///
    /// "changed" is not proof the command worked: a blinking caret, the
    /// menu-bar clock, a notification or a playing video all change the
    /// screen on their own. It is evidence, not a verdict, and nothing
    /// branches on it — it goes in the journal for a human to read alongside
    /// what they asked for.
    static var caveat: String {
        "screen-change only; idle animation can read as changed"
    }

    /// And what a MISSING verdict means.
    ///
    /// The "before" frame is captured alongside the command rather than
    /// before it, so that the check costs the command nothing. A capture
    /// is an XPC round trip and a keystroke is microseconds, so the
    /// frame often lands after the effect has already painted — and a
    /// comparison against that frame would report "no-change" for a
    /// command that worked. When the frame did not land in time the
    /// journal's `verified` field is simply absent, which means "could
    /// not tell", not "nothing happened".
    static var missing: String {
        // Deliberately not "the command was too fast". The before-frame
        // can also be absent because the capture itself failed —
        // Screen Recording revoked, the display asleep, the session
        // dead — and blaming a race that did not happen is the kind of
        // confidently wrong diagnostic this whole file exists to stop.
        "no before-frame to compare against"
    }

    /// Commands worth checking.
    ///
    /// Only the ones that claim to change something and cannot prove it
    /// themselves. A click through the driver already comes back with the
    /// control it pressed, and asking for a form is a question rather than an
    /// action — checking those would cost two captures to learn nothing.
    static func worthChecking(_ command: Command) -> Bool {
        switch command {
        case .pressKeys, .typeText, .scroll, .systemAction, .switchWorkspace,
             // These report that the driver delivered, never that the app
             // acted — the file that implements them says so in detail: a
             // stale handle "is delivered with no error and no effect".
             .clickControl, .rightClickControl, .fillField, .openURL:
            return true
        // Deliberately not checked: clickPoint and pointerAction MOVE the
        // cursor, and a moved cursor is a changed screen whatever else
        // happened, so the answer would be "changed" every time and mean
        // nothing. They need a different check, not a misleading one.
        case .sequence(_, let steps):
            return steps.contains(where: worthChecking)
        default:
            return false
        }
    }
}
