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
