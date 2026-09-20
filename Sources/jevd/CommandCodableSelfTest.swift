import Foundation
import JevCore

/// Every Command must survive being written down and read back.
///
/// `Command` hand-rolls its Codable conformance across a shared set of coding
/// keys, so a case can easily encode into one key and decode out of another.
/// Nothing crashes when that happens — the value just comes back wrong, or
/// fails to decode at all, at the point where a command crosses the wire or is
/// replayed from a log. Checking every case by round trip is the only way to
/// know, and it costs microseconds at launch.
enum CommandCodableSelfTest {

    /// One of each case. Values are deliberately distinctive so a field landing
    /// in the wrong slot is visible rather than coincidentally equal.
    private static let samples: [Command] = [
        .launchApp(bundleIdentifier: "com.apple.Notes"),
        .quitApp(bundleIdentifier: "com.apple.Safari"),
        .toggleApp(bundleIdentifier: "com.apple.Terminal"),
        .showApp(bundleIdentifier: "com.apple.Finder"),
        .hideApp(bundleIdentifier: "com.apple.Mail"),
        .clickControl(label: "Submit"),
        // Command.init(from:) switches on a String with `default: throw`, so
        // the compiler does NOT flag a case that was added to the encoder and
        // forgotten here. Without these two rows a parked web task would come
        // back as "Unknown command type: webTask" after the person taps
        // Approve — the one moment it must not fail.
        // The name, never the value — see the assertions below.
        .fillDetail(name: "TIN"),
        .webTask(goal: "play blinding lights on youtube"),
        .webTask(goal: "open the first result", startURL: "https://www.amazon.com/"),
        // The ordinal has to survive the wire, or "press number two"
        // arrives as "press the only one" and the executor refuses.
        .clickControl(label: "Follow", nth: 2, outOf: 3),
        // The window the candidates were counted in has to survive too,
        // or the answer lands wherever is frontmost when it arrives.
        .clickControl(label: "Follow", nth: 2, outOf: 3, inWindow: 4211),
        .rightClickControl(label: "Follow", nth: 2, outOf: 3, inWindow: 4211),
        // The separator carries the ordinal, so a label that CONTAINS
        // one must come back as itself rather than being split.
        .clickControl(label: "a\u{001F}b"),
        .clickControl(label: "a\u{001F}2"),
        // …including a label with the punctuation an accessibility name
        // routinely carries.
        .clickControl(label: "Save As\u{2026}", nth: 3, outOf: 4),
        .showNumbers(on: true),
        // BOTH, because the decoder defaults a missing `on` to true. With
        // only the `true` sample, deleting the encode line leaves the round
        // trip byte-identical and the test passes — and "show and hide sent
        // the same message" is the exact bug this file is here to catch.
        .showNumbers(on: false),
        .typeText(text: "hello world"),
        .clickPoint(x: 12.5, y: 34.25),
        .scroll(direction: "down", amount: 7),
        .switchWorkspace(id: "3"),
        .pressKeys(spec: "cmd+shift+t"),
        .rightClickControl(label: "Sidebar item"),
        .fillField(label: "email", text: "someone@example.com"),
        .openURL(url: "https://example.com/a?b=c"),
        .systemAction(name: "volumeSet", value: 42),
        .pointerAction(kind: "right"),
        .requestInput(field: "password", secret: true),
        .requestInput(field: "text", secret: false),
        .showForm,
        .pressButton(requestId: "req-1", optionId: "Allow"),
        .runCommand(allowlistedPrefix: "/bin/echo", fullCommand: "/bin/echo hi"),
        .answerAgentPrompt(requestId: "req-2", optionId: "2"),
        .sequence(label: "Two steps", steps: [
            .pressKeys(spec: "cmd+a"),
            .typeText(text: "replacement"),
        ]),
    ]

    static func run() -> [String] {
        var failures: [String] = []
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let decoder = JSONDecoder()

        for command in samples {
            let name = label(for: command)
            guard let first = try? encoder.encode(command) else {
                failures.append("codable: \(name) cannot be encoded"); continue
            }
            do {
                let decoded = try decoder.decode(Command.self, from: first)
                let second = try encoder.encode(decoded)
                if first != second {
                    let a = String(data: first, encoding: .utf8) ?? "?"
                    let b = String(data: second, encoding: .utf8) ?? "?"
                    failures.append("codable: \(name) changed on round trip — \(a) became \(b)")
                }
            } catch {
                let json = String(data: first, encoding: .utf8) ?? "?"
                failures.append("codable: \(name) encodes to \(json) but will not decode (\(error))")
            }
        }

        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append("webtask: \(name)") }
        }

        // Its own policy bucket. Unknown bundle ids inherit the global mode,
        // which defaults to .auto, so sharing system.browser with openURL
        // would mean a sixty-action loop inheriting permission granted for
        // opening a page.
        let task = Command.webTask(goal: "buy more coffee filters")
        check("a web task has its own policy bucket",
              task.bundleIdentifier == "system.webtask")
        check("and does not share one with openURL",
              task.bundleIdentifier != Command.openURL(url: "https://x/").bundleIdentifier)

        // A goal is free text and reaches a model and the journal: "search for
        // 4111 1111 1111 1111" is a web task like any other.
        check("a web task is treated as carrying free text",
              CommandJournal.carriesFreeText(task))
        check("and the goal is what gets redacted",
              CommandJournal.carriedText(task) == ["buy more coffee filters"])

        // A saved detail's VALUE must never be reachable from the command.
        //
        // This is the whole safety story for personal details, and it is
        // structural rather than careful: `.fillDetail` carries a name, the
        // executor fetches the value one line before typing it, and so there
        // is nothing here for a journal entry, an approval card or a log line
        // to leak — and nothing anyone has to remember to redact. These
        // assertions exist so that stays true.
        let detail = Command.fillDetail(name: "TIN")
        let encoded = (try? encoder.encode(detail)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        check("a detail command names the field", encoded.contains("TIN"))
        check("a detail command is not treated as carrying free text",
              !CommandJournal.carriesFreeText(detail))
        check("and so has no carried text to redact",
              CommandJournal.carriedText(detail).isEmpty)

        // A command for a field carries the field and nothing else. Checked
        // without reading the vault: a launch assertion must not do I/O, and
        // reading twelve Keychain entries here hung the daemon before it
        // logged a line — a Keychain read can raise a prompt, and a prompt
        // nobody can answer blocks forever.
        for field in PersonalDetails.known {
            let bytes = (try? encoder.encode(Command.fillDetail(name: field.name)))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            // The only field carrying anything is the name.
            let carried = (try? decoder.decode(Command.self, from: Data(bytes.utf8)))
            guard case .fillDetail(let back) = carried, back == field.name else {
                failures.append("webtask: \(field.name) does not round-trip")
                continue
            }
            // Two keys: the type and the name. A value would need a third.
            let keys = (try? JSONSerialization.jsonObject(with: Data(bytes.utf8)))
                .flatMap { ($0 as? [String: Any])?.keys.sorted() } ?? []
            if keys != ["optionId", "type"] {
                failures.append("webtask: \(field.name) encodes unexpected fields \(keys)")
            }
        }

        // Names differ in case, spacing and punctuation between what is said
        // and what is stored. "pag ibig" and "Pag-IBIG" are one field.
        check("a spoken name finds its field",
              PersonalDetails.field(named: "pag ibig")?.name == "Pag-IBIG")
        check("case does not matter", PersonalDetails.field(named: "tin")?.name == "TIN")
        check("punctuation does not matter",
              PersonalDetails.field(named: "drivers licence")?.name == "driver's licence")
        check("an unknown field is not invented",
              PersonalDetails.field(named: "mother's maiden name") == nil)

        // Keychain accounts are namespaced, or a detail could collide with
        // the pairing token.
        check("storage keys are namespaced",
              PersonalDetails.storageKey(for: "TIN").hasPrefix("detail."))
        check("two fields cannot share a key",
              PersonalDetails.storageKey(for: "TIN") != PersonalDetails.storageKey(for: "SSS"))

        // Masking a two-letter value would rewrite every page containing
        // those letters, which corrupts the page the model has to read.
        check("very short values are not offered for masking",
              PersonalDetails.shortestWorthMasking >= 4)

        // Two different commands must not encode to the same bytes.
        //
        // The round trip above cannot catch a dropped field, because it
        // re-encodes through the same encoder: if `on` stopped being
        // written, `.showNumbers(on: false)` would encode to
        // `{"type":"showNumbers"}`, decode to the default `true`, and
        // re-encode to the same bytes — identical, so it passes. That is
        // precisely the "show and hide sent the same message" bug. Asking
        // instead whether the encodings are DISTINCT catches a dropped
        // field, a hardcoded constant, and a field written to the wrong key.
        var seen: [String: String] = [:]
        for command in samples {
            guard let data = try? encoder.encode(command),
                  let json = String(data: data, encoding: .utf8) else { continue }
            let name = "\(command)"
            if let other = seen[json], other != name {
                failures.append("codable: \(name) and \(other) both encode to \(json)")
            }
            seen[json] = name
        }
        return failures
    }

    private static func label(for command: Command) -> String {
        let mirror = Mirror(reflecting: command)
        return mirror.children.first?.label ?? "\(command)"
    }
}
