import Foundation
#if canImport(Speech)
import Speech
#endif

/// Which language the recogniser listens for.
///
/// This was `en-US`, written into the recogniser's initialiser. On a Mac set
/// to `en_PH` that means Filipino-accented English is transcribed by a model
/// trained on American English, and no amount of matching downstream recovers
/// a word that was never heard.
///
/// Guessing better — following the system, say — would have been the same
/// mistake with a nicer default: the language someone speaks to their Mac is
/// not always the language their Mac is set to, and only they know which it
/// is. So it is a choice, in the menu bar, and the default merely follows the
/// system rather than pretending to know.
enum VoiceLocale {

    static let defaultsKey = "JevSpeechLocale"

    /// Chosen when the language should not be pinned at all.
    ///
    /// Only Gemini can act on this — its transcribe model detects across
    /// eighty-five languages when it is sent no language code, and someone
    /// who switches between English and Tagalog mid-sentence is better served
    /// by that than by being held to one of them. Apple's recogniser has no
    /// equivalent, so it keeps following the Mac.
    static let autoDetect = "auto"

    static var isAutoDetect: Bool { chosen == autoDetect }
    /// The last resort, and only that: every Mac has it, and a recogniser
    /// that will not start is worse than one with the wrong accent.
    static let fallback = "en-US"

    /// What the person picked, or nil for "follow the system".
    static var chosen: String? {
        get {
            let stored = UserDefaults.standard.string(forKey: defaultsKey)
            return (stored?.isEmpty == false) ? stored : nil
        }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }
    }

    /// Every language the installed recogniser can actually handle.
    ///
    /// Asked of the system rather than listed here, because the answer
    /// changes with the OS version and with what the person has downloaded.
    static func supported() -> [String] {
        #if canImport(Speech)
        return SFSpeechRecognizer.supportedLocales().map(\.identifier).sorted()
        #else
        return [fallback]
        #endif
    }

    /// The language to listen in, resolved against what is actually supported.
    ///
    /// Pure, so the fallback order is a launch assertion rather than a hope:
    /// the choice if it is supported, then the system's, then the system's
    /// language without its region — a Mac set to `en_PH` should still find
    /// `en-US` if `en-PH` were ever withdrawn — then `en-US`.
    static func resolve(chosen: String?, system: String, supported: Set<String>) -> String {
        if let chosen, supported.contains(chosen) { return chosen }

        // Locale identifiers use an underscore ("en_PH"); speech uses a
        // hyphen ("en-PH"). They are the same language and did not match.
        let normalised = system.replacingOccurrences(of: "_", with: "-")
        if supported.contains(normalised) { return normalised }

        if let language = normalised.split(separator: "-").first {
            let sameLanguage = supported.filter { $0.hasPrefix(language + "-") }.sorted()
            // Prefer the plain fallback within that language if it is there,
            // so English speakers do not land on a random region.
            if sameLanguage.contains(fallback) { return fallback }
            if let first = sameLanguage.first { return first }
        }
        return supported.contains(fallback) ? fallback : (supported.sorted().first ?? fallback)
    }

    /// The language to listen in, right now.
    static var effective: String {
        // "auto" is not a locale. Apple needs a real one, so it falls back to
        // the Mac's — the sentinel only changes what Gemini is told.
        resolve(chosen: isAutoDetect ? nil : chosen,
                system: Locale.current.identifier,
                supported: Set(supported()))
    }

    /// What to send Gemini. Empty means "work it out".
    static var languageCodes: [String] { isAutoDetect ? [] : [effective] }

    /// How a language is written in the menu.
    static func displayName(_ identifier: String) -> String {
        let pretty = Locale.current.localizedString(forIdentifier: identifier)
        return pretty.map { "\($0)  (\(identifier))" } ?? identifier
    }

    /// What the system would be followed to, for the "follow the system" row.
    static var systemChoiceDescription: String {
        let resolved = resolve(chosen: nil,
                               system: Locale.current.identifier,
                               supported: Set(supported()))
        return "Follow this Mac  (\(resolved))"
    }
}
