import Foundation
import JevCore

/// Scoping: what a bare word means where you are standing.
///
/// The problem this solves: "mute" on YouTube should mute the video, and
/// "mute" in Finder should mute the Mac. Both are correct, and which one you
/// meant is not in the words — it is in the context.
///
/// The model is three scopes and one rule.
///
///   system — the Mac itself: volume, brightness, appearance.
///   app    — the frontmost application.
///   page   — the document or tab inside it.
///
/// **A bare phrase means the narrowest scope that defines it.** If where you
/// are has a profile entry for the phrase, that wins; otherwise the phrase
/// falls through to the generic vocabulary, which is system-wide. So "mute"
/// on YouTube presses `m`, and "mute" in Finder sets the Mac's volume to zero,
/// with no model call and nothing to configure.
///
/// Two sets of words override the rule explicitly, for when the default is
/// not what you want:
///
///   "mute everything", "system volume", "mute the mac" → always the Mac.
///   "mute this", "mute the tab", "mute the video"      → always the page.
enum AppProfiles {

    /// Words that force the system scope, skipping any profile.
    private static let systemScopeWords = [
        "everything", "the mac", "the computer", "system", "globally", "all apps",
    ]

    /// Words that force the narrow scope. They also read naturally as
    /// "the thing I am looking at".
    private static let pageScopeWords = [
        "this", "the tab", "this tab", "the video", "the page", "this page", "here",
    ]

    struct Profile {
        /// Phrase → the steps it means in this context.
        let actions: [String: (label: String, keys: String)]
    }

    /// Keyed by host for pages, and by bundle id for apps.
    ///
    /// Only worth an entry where the app's own shortcut is genuinely better
    /// than the system one — muting a tab rather than the whole machine,
    /// skipping within a video rather than to the next track.
    private static let profiles: [String: Profile] = [
        "youtube.com": Profile(actions: [
            "mute": ("Mute the video", "m"),
            "unmute": ("Unmute the video", "m"),
            "play": ("Play/pause the video", "k"),
            "pause": ("Play/pause the video", "k"),
            "full screen": ("Full screen video", "f"),
            "captions": ("Toggle captions", "c"),
            "subtitles": ("Toggle captions", "c"),
            "next track": ("Next video", "shift+n"),
            "previous track": ("Previous video", "shift+p"),
            "faster": ("Speed up", "shift+period"),
            "slower": ("Slow down", "shift+comma"),
            "skip forward": ("Forward 10 seconds", "l"),
            "skip back": ("Back 10 seconds", "j"),
            "theater mode": ("Theater mode", "t"),
        ]),
        "netflix.com": Profile(actions: [
            "mute": ("Mute", "m"),
            "unmute": ("Unmute", "m"),
            "play": ("Play/pause", "space"),
            "pause": ("Play/pause", "space"),
            "full screen": ("Full screen", "f"),
        ]),
        "twitch.tv": Profile(actions: [
            "mute": ("Mute the stream", "m"),
            "unmute": ("Unmute the stream", "m"),
            "full screen": ("Full screen", "f"),
            "theater mode": ("Theater mode", "alt+t"),
        ]),
        // Apps, keyed by bundle id.
        "com.spotify.client": Profile(actions: [
            "play": ("Play/pause", "space"),
            "pause": ("Play/pause", "space"),
            "next track": ("Next track", "cmd+right"),
            "previous track": ("Previous track", "cmd+left"),
        ]),
        "com.apple.Music": Profile(actions: [
            "play": ("Play/pause", "space"),
            "pause": ("Play/pause", "space"),
        ]),
        "org.videolan.vlc": Profile(actions: [
            "mute": ("Mute", "cmd+alt+down"),
            "play": ("Play/pause", "space"),
            "pause": ("Play/pause", "space"),
            "full screen": ("Full screen", "cmd+f"),
        ]),
    ]

    /// The profile in force right now: the page's if there is one, else the app's.
    /// Narrower beats wider, which is the whole rule.
    static func current(bundleId: String, host: String?) -> (key: String, profile: Profile)? {
        if let host {
            if let profile = profiles[host] { return (host, profile) }
            // A subdomain of a profiled site counts, so music.youtube.com works.
            if let match = profiles.first(where: { host.hasSuffix("." + $0.key) }) {
                return (match.key, match.value)
            }
        }
        return profiles[bundleId].map { (bundleId, $0) }
    }

    /// Resolve a phrase against the current context. Nil means "no opinion" —
    /// the caller falls through to the generic, system-wide vocabulary.
    static func override(for text: String, in context: Phrasebook.Context) -> VoiceCommand.Parsed? {
        if systemScopeWords.contains(where: { text.contains($0) }) { return nil }

        // Strip a trailing scope word so "mute this" and "mute" both land on
        // the profile's "mute".
        var phrase = text
        for word in pageScopeWords where phrase.hasSuffix(" " + word) {
            phrase = String(phrase.dropLast(word.count + 1))
        }

        guard let (key, profile) = current(bundleId: context.bundleId, host: context.host),
              let action = profile.actions[phrase] else { return nil }

        return VoiceCommand.Parsed(
            command: .sequence(label: action.label, steps: [.pressKeys(spec: action.keys)]),
            description: "\(action.label) (\(key))")
    }

    /// Every phrase the current context defines, for telling the user what
    /// changed meaning where they are.
    static func phrases(bundleId: String, host: String?) -> [String] {
        current(bundleId: bundleId, host: host).map { Array($0.profile.actions.keys).sorted() } ?? []
    }
}
