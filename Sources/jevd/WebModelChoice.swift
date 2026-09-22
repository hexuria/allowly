import Foundation
import JevWeb

/// Which model writes into a form field during a browser task.
///
/// This existed only as `ALLOWLY_WEB_TEXT_MODEL`, read through
/// `Allowly.environment`, which checks the process environment and nothing
/// else. `open` inherits no shell, so for `/Applications/Allowly.app` under
/// launchd that variable can never be set — the model was not merely wrong by
/// default, it was unchangeable. The API keys hit the same trap and were given
/// a file to fall back to; this was missed.
///
/// So it is a setting the menu bar owns, in the shape `VoiceLocale` already
/// uses for exactly that.
enum WebModelChoice {

    static let defaultsKey = "AllowlyWebTextModel"

    /// What the model is when nobody has said otherwise. Deliberately still
    /// the old value: shipping a different hardcoded default while calling the
    /// feature configurable would be the same bug in a new coat.
    ///
    /// Taken from `WebTextModel` rather than written again, so the menu cannot
    /// name one default while the request sends another.
    static let fallback = WebTextModel.defaultModel

    /// What was picked from the menu, or nil for "whatever the default is".
    ///
    /// `UserDefaults.standard`, which is local to this Mac — nothing here uses
    /// `NSUbiquitousKeyValueStore`, so there is no cross-machine sync to
    /// reason about.
    static var chosen: String? {
        get {
            let stored = UserDefaults.standard.string(forKey: defaultsKey)
            return (stored?.isEmpty == false) ? stored : nil
        }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                UserDefaults.standard.set(trimmed, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }
    }

    /// What the environment says, both spellings, exactly as the request path
    /// reads it.
    static var environment: String? { WebTextModel.modelFromEnvironment }

    /// The model in force.
    ///
    /// Forwards to `WebTextModel.effective`, which is the one copy of the
    /// rule — the menu has to show what the request will actually send, and a
    /// second implementation of the same precedence is how those two drift
    /// apart without anybody noticing.
    static func effective(stored: String?, environment: String?) -> String {
        WebTextModel.effective(stored: stored, environment: environment)
    }

    /// The model in force right now, read from the two places that decide it.
    static var effective: String {
        effective(stored: chosen, environment: environment)
    }

    /// For the log line at startup, so a surprising model is traceable to the
    /// thing that set it.
    static func source(stored: String?, environment: String?) -> String {
        if let stored, !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "the menu bar"
        }
        if let environment,
           !environment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "the environment"
        }
        return "the built-in default"
    }

    // MARK: - Which row is ticked

    /// Exactly one row in the submenu carries a checkmark, and this says which.
    ///
    /// Computed rather than decided per row, because deciding per row is how
    /// two of them ended up ticked: "Use the default" ticked whenever nothing
    /// was stored, and separately every catalog row ticked when its id matched
    /// the model in force — which, with nothing stored, is the default, and the
    /// default is in the list. The menu claimed two different answers at once.
    ///
    /// The environment does not enter into it. A stored choice beats the
    /// environment, so when something is stored it is what is in force, and
    /// when nothing is stored the row that says "nothing is stored" is the
    /// honest one to mark.
    enum Tick: Equatable {
        case useTheDefault
        case model(String)
        /// Stored, but the gateway does not offer it any more.
        case noLongerOffered(String)
    }

    static func tick(chosen: String?, listed: [String]) -> Tick {
        guard let chosen = chosen?.trimmingCharacters(in: .whitespacesAndNewlines),
              !chosen.isEmpty else {
            return .useTheDefault
        }
        return listed.contains(chosen) ? .model(chosen) : .noLongerOffered(chosen)
    }
}
