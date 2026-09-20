import Foundation

/// Locating the vendored table builder, without `Bundle.module`.
///
/// SwiftPM's generated `Bundle.module` accessor is unusable here for two
/// reasons, both of which bite in the signed app rather than in `swift build`:
///
/// 1. It calls `Swift.fatalError` when the bundle is missing. A daemon that
///    traps at launch is strictly worse than one that reports a failed
///    self-test, and every other missing-resource path in jev reports.
/// 2. Its fallback is a hard-coded absolute path to the build directory of
///    whichever machine compiled it. On that machine the resource resolves even
///    when the app bundle does not contain it, so the bug tests clean exactly
///    where it is introduced and crashes everywhere else.
///
/// So the lookup is explicit, ordered by how much we trust the location, and
/// returns nil rather than trapping. `WebSelfTest` turns that nil into a
/// failed launch assertion naming the file.
enum SnapshotSource {

    /// SwiftPM names the resource bundle after `<package>_<target>` and, on
    /// macOS, lays it out flat rather than as a framework.
    static let bundleName = "jev_JevWeb.bundle"
    static let resourceName = "snapshot.js"

    /// Everywhere the bundle can legitimately be, best first.
    ///
    /// - Inside the signed app, where `scripts/build-app.sh` puts it.
    /// - Beside the executable, which is where SwiftPM leaves it for
    ///   `swift build` and `swift run`.
    static func candidateURLs(
        mainBundle: Bundle = .main,
        executableURL: URL? = Bundle.main.executableURL
    ) -> [URL] {
        var candidates: [URL] = []

        if let resources = mainBundle.resourceURL {
            candidates.append(resources.appendingPathComponent(bundleName))
        }
        candidates.append(mainBundle.bundleURL.appendingPathComponent(bundleName))
        if let executable = executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() {
            candidates.append(executable.appendingPathComponent(bundleName))
        }

        return candidates.map { $0.appendingPathComponent(resourceName) }
    }

    /// The vendored source, or nil when it is not installed.
    ///
    /// Never throws and never traps: a missing table builder means the browser
    /// backend cannot run, not that the daemon cannot start.
    static func load() -> String? {
        for url in candidateURLs() {
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                return text
            }
        }
        return nil
    }
}
