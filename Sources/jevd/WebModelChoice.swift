import Foundation

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
    static let fallback = "openai/gpt-5.6-luna"

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

    /// The model in force, and where it came from.
    ///
    /// Pure, so the precedence is a launch assertion rather than a claim.
    ///
    /// The stored choice beats the environment, which is the reverse of the
    /// order `WebTextModel.loadAPIKey` uses, and the reversal is deliberate: a
    /// menu somebody clicked has to visibly take effect, or the menu is a lie.
    /// The environment is what remains for a terminal launch that has never
    /// picked anything — scripts, CI, a developer with a shell.
    ///
    /// An empty or blank stored string is not a choice.
    static func effective(stored: String?, environment: String?) -> String {
        if let stored = stored?.trimmingCharacters(in: .whitespacesAndNewlines),
           !stored.isEmpty {
            return stored
        }
        if let environment = environment?.trimmingCharacters(in: .whitespacesAndNewlines),
           !environment.isEmpty {
            return environment
        }
        return fallback
    }

    /// For the log line at startup, so a surprising model is traceable to the
    /// thing that set it.
    static func source(stored: String?, environment: String?) -> String {
        if let stored, !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "the menu bar"
        }
        if let environment,
           !environment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "ALLOWLY_WEB_TEXT_MODEL"
        }
        return "the built-in default"
    }
}
