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
        return dir.appendingPathComponent("jev.log")
    }()

    static func write(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(message)\n"
        print(message)
        queue.async {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: fileURL)
            }
        }
    }
}
