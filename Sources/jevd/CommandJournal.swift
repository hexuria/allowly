import Foundation
import JevCore

/// One line per command, so "it said Done and nothing happened" is a thing
/// you can look up rather than argue about.
///
/// The prose log already says a great deal, but it says it across a dozen
/// lines with nothing tying them together, no timings, and — the part that
/// actually matters — no record of whether the command *worked*. A keystroke
/// command reports `ok` the moment it is posted; whether the Mac acted on it
/// is a different question and was never written down anywhere. So `close
/// tab` succeeding one time in three looked exactly like it succeeding every
/// time.
///
/// Each entry is a single JSON object on its own line, which means `tail -f`,
/// `grep`, and `jq` all work on it without ceremony.
enum CommandJournal {

    struct Entry: Codable, Sendable {
        let at: String
        /// What was said, or typed, or posted.
        let heard: String
        /// Which path claimed it: vocabulary, screen, model, finishing, tap.
        let route: String
        /// What it became.
        let command: String
        let status: String
        let reason: String
        let ms: Int
        /// What was in front at the time — the single most useful thing when
        /// a command goes somewhere unexpected.
        let app: String
        /// Where the effect could be checked, what the check said.
        let verified: String?
        /// What Jev's numbers were, when a model produced them.
        ///
        /// These went to the log and nowhere else, and the log rotates. So
        /// the confidence floor that decides whether a command runs or waits
        /// for you could never be checked against what it actually did —
        /// measured tonight, on a journal of 85 real commands, and the answer
        /// was "no data". A floor tuned on remembered examples is a floor
        /// nobody can argue with. Numbers, not words: there is nothing here
        /// anyone said, so nothing to redact.
        let confidence: Double?
        let routine: Double?
        let destructive: Double?
        /// Which of the six reasons put a card in front of you.
        let asked: String?
    }

    /// The numbers behind one decision, for the journal.
    struct Judgement: Sendable, Equatable {
        var confidence: Double?
        var routine: Double?
        var destructive: Double?
        var asked: String?

        /// Rounded to two places. A journal is read by a person and diffed by
        /// a script; seventeen digits of Double help neither.
        static func round(_ value: Double?) -> Double? {
            value.map { (($0 * 100).rounded()) / 100 }
        }
    }

    /// What was said, minus anything that should not be on disk.
    ///
    /// `fillField` was already redacted and the typed-text route already logs
    /// `<secret>`, but the spoken path was not: "type my card number is 4111
    /// 1111 1111 1111" landed here in plain text and was served over HTTP by
    /// /api/journal. The verb is the useful part; the value never is.
    /// Does this command carry words the person supplied?
    ///
    /// Decided from the command, not from how the sentence was phrased.
    /// Matching verb prefixes was the wrong idea and leaked: "search for
    /// 4111 1111 1111 1111" starts with none of type/write/say/fill, so the
    /// card number went to disk in three fields and out over /api/journal.
    /// Every phrase that carries a value ends up typing it or opening it, so
    /// the command tree is where the truth is.
    static func carriesFreeText(_ command: Command?) -> Bool {
        guard let command else { return false }
        switch command {
        case .typeText, .fillField, .openURL, .webTask:
            // A goal is free text and reaches a model: "search for
            // 4111 1111 1111 1111" is a web task like any other.
            return true
        case .sequence(_, let steps):
            return steps.contains(where: carriesFreeText)
        default:
            return false
        }
    }

    /// The words this command will actually type, fill or open.
    static func carriedText(_ command: Command?) -> [String] {
        guard let command else { return [] }
        switch command {
        case .typeText(let text): return [text]
        case .fillField(_, let text): return [text]
        case .openURL(let url): return [url]
        // The goal only. A start URL is resolved from jev's own site list or
        // from the page already open, so it is never something the person said.
        case .webTask(let goal, _): return [goal]
        case .sequence(_, let steps): return steps.flatMap(carriedText)
        default: return []
        }
    }

    /// Is the very first word of what was said part of the VALUE?
    ///
    /// `redacted` keeps the first word on the grounds that it is the verb.
    /// That is right for "type hunter2" and wrong for "hunter2" — which is
    /// what the model route gets when speech drops the leading verb, or when
    /// a pending "type" expired and the bare answer arrived on its own. The
    /// model then resolves the whole transcript to `.typeText`, `carries` is
    /// true, and the journal wrote the secret as "the verb": `"hunter2 <not
    /// recorded>"`. Comparing against what the command will actually type
    /// settles it without guessing.
    static func startsWithTheValue(_ text: String, _ command: Command?) -> Bool {
        let first = text.split(separator: " ").first.map(String.init) ?? text
        let opening = first.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !opening.isEmpty else { return false }
        return carriedText(command).contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix(opening)
        }
    }

    /// A command's own description, safe to put in a log line.
    ///
    /// `JevLog.safe` cannot do this job: it keys on a leading verb or a run
    /// of four digits, and a Phrasebook description is neither — it is
    /// `Search for “5555 4444 3333”`, which starts with a word that is not on
    /// its list. Four log lines were writing exactly that.
    static func safeDescription(_ description: String, _ command: Command?) -> String {
        redacted(description, carriesText: carriesFreeText(command))
    }

    /// Nothing of the words survives.
    ///
    /// For an utterance that no command claimed. `redacted` keeps the first
    /// word on the grounds that it is the verb — true for “type hunter2”,
    /// false for an utterance nothing parsed, where the whole of it may be
    /// the value. “4111 1111 1111 1111” kept “4111”: the card's BIN.
    /// One rule for every field that could hold something dictated.
    static func clean(_ text: String, keepNothing: Bool, carries: Bool) -> String {
        // A placeholder jev wrote itself, like "-", is not a transcript.
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return text }
        return keepNothing ? withheld(text) : redacted(text, carriesText: carries)
    }

    static func withheld(_ text: String) -> String {
        let cuts: [Character] = ["\u{201C}", "\"", "("]
        if let open = text.firstIndex(where: { cuts.contains($0) }) {
            return String(text[..<open]) + "<not recorded>"
        }
        return "<not recorded>"
    }

    static func redacted(_ text: String, carriesText: Bool) -> String {
        guard carriesText else { return text }

        // Keep the verb, drop everything it carries — whichever shape the
        // value arrives in. There are three: quoted ("Type “…”"), bracketed
        // ("typeText(…)"), and bare ("type my card number is …"). Cutting at
        // the first quote alone left "typeText(4111" on disk, which the
        // assertion caught and I had not.
        let cuts: [Character] = ["\u{201C}", "\"", "("]
        if let open = text.firstIndex(where: { cuts.contains($0) }) {
            return String(text[..<open]) + "<not recorded>"
        }
        let words = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        return (words.first.map(String.init) ?? "") + " <not recorded>"
    }

    private static let lock = NSLock()
    private static let limit = 400

    static var path: String {
        let dir = Allowly.supportDirectory
        // Do not rely on something else having made it. It only worked
        // because JevLog happens to create the same directory first.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("commands.jsonl").path
    }

    static func record(heard: String,
                       route: String,
                       command: String,
                       kind: Command?,
                       result: ExecutionResult,
                       started: Date,
                       app: String,
                       verified: String? = nil,
                       /// Nothing parsed this, so there is no command to key
                       /// the redaction on and no verb worth keeping. An
                       /// unparseable utterance is exactly where a misheard
                       /// secret lands — speech drops leading verbs all the
                       /// time — and with `kind` nil it was the one path that
                       /// wrote the transcript to disk verbatim.
                       unparsed: Bool = false,
                       /// A reason jev wrote itself, which therefore needs
                       /// no redaction. Without this the type route's
                       /// journal line — added so typed text finally had
                       /// one — could not say why a fill failed: "That
                       /// form changed while you were typing" came out as
                       /// "That <not recorded>", because the command
                       /// carries free text so every field was treated as
                       /// if it might.
                       reasonIsOurs: Bool = false,
                       /// Override when the entry is written later than the
                       /// command finished — a verification that runs after
                       /// the answer has already gone must not report its own
                       /// wait as the command's latency.
                       tookMs: Int? = nil,
                       /// What the model said, when one was asked.
                       judged: Judgement? = nil) {
        let carries = Self.carriesFreeText(kind)
        // Keep nothing when there is no verb to keep — either because
        // nothing parsed this, or because the first word turned out to be
        // the value rather than a verb in front of it.
        let keepNothing = unparsed || Self.startsWithTheValue(heard, kind)
        func clean(_ text: String) -> String {
            Self.clean(text, keepNothing: keepNothing, carries: carries)
        }
        let entry = Entry(
            // The command's own time, not the moment this line was written.
            // A verified command is journalled ~400 ms late, so using "now"
            // put entries out of order and made sorting by `at` useless.
            at: ISO8601DateFormatter().string(from: started),
            heard: clean(heard),
            route: route,
            // Every field, not just the one. Redacting `heard` alone left the
            // card number in `command` ("Type “…4111…”") and again in
            // `reason`, because the description a Phrasebook step builds
            // quotes the text back. Measured, after assuming otherwise.
            // Through `clean` too, not `redacted`. The asymmetry was a trap:
            // on a keep-nothing route this field was still getting the
            // keep-the-first-word treatment, and a model-written description
            // is not guaranteed to start with a verb.
            command: Self.clean(command, keepNothing: keepNothing, carries: carries),
            status: result.status == .ok ? "ok" : "failed",
            reason: reasonIsOurs ? result.reason : clean(result.reason),
            ms: tookMs ?? Int(Date().timeIntervalSince(started) * 1000),
            app: app,
            verified: verified,
            confidence: Judgement.round(judged?.confidence),
            routine: Judgement.round(judged?.routine),
            destructive: Judgement.round(judged?.destructive),
            asked: judged?.asked)

        guard let data = try? JSONEncoder().encode(entry),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"

        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            // 0600, like the log and the token beside it. This file is a
            // record of everything anyone has asked this Mac to do.
            fm.createFile(atPath: path, contents: Data(line.utf8),
                          attributes: [.posixPermissions: 0o600])
        } else if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            // "Exactly one journal line per command" is a contract, and a
            // silent drop breaks it invisibly — which is the failure mode
            // the journal exists to make impossible. Say so in the log.
            JevLog.write("[allowly] journal: could not append to \(path)")
        }
        trimLocked()
    }

    /// The last `count` entries, newest first.
    static func recent(_ count: Int = 50) -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n")
            .suffix(count)
            .reversed()
            .compactMap { decoder.decode(Entry.self, fromLine: String($0)) }
    }

    /// Keep the file small enough to read. A control surface does not need a
    /// year of history; it needs the last few minutes, instantly.
    private static func trimLocked() {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > limit else { return }
        let kept = lines.suffix(limit).joined(separator: "\n") + "\n"
        try? kept.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

private extension JSONDecoder {
    func decode<T: Decodable>(_ type: T.Type, fromLine line: String) -> T? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? decode(type, from: data)
    }
}
