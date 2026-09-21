import Foundation

/// Product identity. Internal Swift modules still say Jev*; this is the name
/// on the bundle, the menu bar, the phone, and the disk.
///
/// TypeSafe's classifier is still called Jev (`jev-latest`). That collision
/// is why this app is not.
public enum Allowly {
    public static let name = "Allowly"
    public static let bundleIdentifier = "dev.goldcoders.allowly"
    public static let daemon = "allowlyd"
    public static let supportDirectoryName = "allowly"
    public static let logFileName = "allowly.log"
    public static let legacySupportDirectoryName = "jev"
    public static let legacyBundleIdentifier = "com.jev.agent"

    /// `~/Library/Application Support/allowly`, created if needed.
    ///
    /// An existing `jev` directory is moved here on first launch so pairing
    /// tokens, keys and the decision ledger survive the rename.
    public static var supportDirectory: URL {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let fresh = home.appendingPathComponent(
            "Library/Application Support/\(supportDirectoryName)", isDirectory: true)
        let legacy = home.appendingPathComponent(
            "Library/Application Support/\(legacySupportDirectoryName)", isDirectory: true)
        migrateLegacyIfNeeded(from: legacy, to: fresh)
        try? fm.createDirectory(at: fresh, withIntermediateDirectories: true)
        return fresh
    }

    public static var logFile: URL {
        let fresh = supportDirectory.appendingPathComponent(logFileName)
        let legacy = supportDirectory.appendingPathComponent("jev.log")
        if !FileManager.default.fileExists(atPath: fresh.path),
           FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: fresh)
        }
        return fresh
    }

    /// First non-empty environment value among `keys`.
    public static func environment(_ keys: String...) -> String? {
        for key in keys {
            if let value = ProcessInfo.processInfo.environment[key]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func migrateLegacyIfNeeded(from legacy: URL, to fresh: URL) {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let freshExists = fm.fileExists(atPath: fresh.path, isDirectory: &isDirectory)
        guard !freshExists else { return }
        guard fm.fileExists(atPath: legacy.path, isDirectory: &isDirectory) else { return }
        try? fm.moveItem(at: legacy, to: fresh)
    }
}
