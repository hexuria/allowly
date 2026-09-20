import Foundation

/// A menu bar app has no console, so `print` goes nowhere once it is launched
/// normally. Everything worth knowing goes here instead:
///   tail -f ~/Library/Application\ Support/jev/jev.log
enum JevLog {
    private static let queue = DispatchQueue(label: "com.jev.log")

    static let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/jev", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("jev.log")
        // 0600, like the token file next to it. This was 0644 while the
        // pairing token it used to print was 0600 — so the log handed the
        // credential to any process running as this user, and undid the
        // care taken with the file beside it.
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil,
                                           attributes: [.posixPermissions: 0o600])
        } else {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: url.path)
        }
        return url
    }()

    /// A transcript, minus anything that looks like a dictated value.
    ///
    /// A BACKSTOP, not a filter. It fires on a leading verb from a short
    /// list or on four digits, so "my password is hunter2" goes through it
    /// untouched. Anything that knows what command it is holding should use
    /// `CommandJournal.safeDescription` instead, which keys on the command
    /// tree rather than guessing from the words.
    ///
    /// The journal was redacted and this file was not, so the same utterance
    /// that `commands.jsonl` carefully withheld was sitting in cleartext in
    /// `jev.log` — 385 of them on the machine this was found on, in the file
    /// the README tells you to tail. A log is not a lesser place for a
    /// secret to be.
    /// How much was said, never what.
    ///
    /// For a transcript nothing has interpreted yet. `safe` can only redact
    /// shapes it recognises, and the shape it cannot recognise is a bare
    /// value: say "type", let the pending window lapse, answer "hunter2",
    /// and `safe` returns "hunter2" — no leading verb from its list, fewer
    /// than four digits. The journal withheld that correctly and this file
    /// wrote it out one function earlier, which is the file the README
    /// tells you to tail.
    ///
    /// The rule this replaces it with: **log what jev understood, never
    /// what it merely heard.** A reading that names a control on screen or
    /// parses as a command has been interpreted and can be logged; the raw
    /// transcript has not.
    /// Make everything jev keeps private to this account.
    ///
    /// Chmodding at the point of WRITE is not enough: the VAPID signing
    /// key, the push subscriptions and the saved app modes are written
    /// once and then read for months, so an existing install stays at
    /// 0644 until something happens to rewrite them — which for the key is
    /// never. This runs at every launch and fixes what is already on disk.
    ///
    /// The whole directory, deliberately. It holds the pairing token, the
    /// API key, the push identity, a record of every command, and the file
    /// that decides what runs unattended. None of it is anyone else's.
    static func protectSupportFiles() {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names {
            let path = dir.appendingPathComponent(name).path
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            let current = (try? fm.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)??.intValue
            guard current != 0o600 else { continue }
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            write("[jev] tightened \(name) to owner-only")
        }
    }

    static func shape(_ transcript: String) -> String {
        let words = transcript.split(whereSeparator: \.isWhitespace).count
        // Bucketed, not exact. The precise length of a passphrase is a real
        // fact about it, sitting next to a timestamp that says when it was
        // typed. Enough to tell "nothing was heard" from "a sentence was".
        let size: String
        switch transcript.count {
        case 0: size = "empty"
        case 1..<10: size = "short"
        case 10..<40: size = "a phrase"
        default: size = "long"
        }
        return "\(words) word\(words == 1 ? "" : "s"), \(size)"
    }

    static func safe(_ transcript: String) -> String {
        let lower = transcript.lowercased()
        for verb in ["type", "write", "enter text", "say", "fill",
                     "search for", "search", "find", "new note", "go to"]
        where lower == verb || lower.hasPrefix(verb + " ") {
            return verb + " …"
        }
        // A bare run of digits is a code, a card or a PIN far more often
        // than it is a command.
        if transcript.filter(\.isNumber).count >= 4 { return "…" }
        return transcript
    }

    /// Write and WAIT. For the last line before the process ends.
    ///
    /// `write` hands the line to a background queue, so a `fatalError`
    /// on the next statement kills the process before it drains — the
    /// explanation for why jev refused to start never reached the file
    /// the explanation tells you to read.
    static func writeNow(_ message: String) {
        write(message)
        queue.sync { }
    }

    /// Keep the log to a readable size.
    ///
    /// Nothing rotated it — `Tailnet.loggableURL`'s comment says so in
    /// as many words, as the reason a token must never reach it. A
    /// daemon that runs for weeks turns the file the README tells you
    /// to tail into something no one can read, and the fifty lines that
    /// matter today are lost among them.
    ///
    /// One generation back, so the last few days survive a rotation.
    private static let sizeCeiling = 8 * 1024 * 1024
    private nonisolated(unsafe) static var writesSinceCheck = 0

    private static func rotateIfHuge() {
        // Not on every line: a stat per log write is a syscall for
        // nothing 99% of the time.
        writesSinceCheck += 1
        guard writesSinceCheck >= 200 else { return }
        writesSinceCheck = 0
        guard let attributes = try? FileManager.default
                .attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? Int, size > sizeCeiling else { return }
        let previous = fileURL.deletingLastPathComponent()
            .appendingPathComponent("jev.log.1")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: fileURL, to: previous)
        FileManager.default.createFile(
            atPath: fileURL.path,
            contents: Data("\(ISO8601DateFormatter().string(from: Date())) [jev] log rotated\n".utf8),
            attributes: [.posixPermissions: 0o600])
    }

    static func write(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(message)\n"
        print(message)
        queue.async {
            rotateIfHuge()
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else if !FileManager.default.fileExists(atPath: fileURL.path) {
                // Only when there is no file yet. Unconditionally, this
                // REPLACED the log with a single line the first time
                // opening it for append failed transiently — the whole
                // history gone, in the file the README tells you to tail.
                //
                // Created at 0600, not at whatever the umask says. A
                // plain write lands 0644 (measured), and this is the
                // file that carries every app name, every dialog title
                // and every command the person ran. `protectSupportFiles`
                // would fix it, but not until the next launch.
                FileManager.default.createFile(
                    atPath: fileURL.path, contents: Data(line.utf8),
                    attributes: [.posixPermissions: 0o600])
            }
        }
    }
}
