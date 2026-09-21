import Foundation
import JevWeb
import AppKit
#if canImport(Speech)
@preconcurrency import Speech
#endif

enum Transcription {
    /// Words worth biasing the recogniser toward: every installed app, plus the
    /// verbs that only make sense as commands. Capped because the API degrades
    /// with very large hint lists.
    static func recognitionHints() -> [String] {
        // Running apps first. The list is capped, and the old order let the
        // command phrases eat most of the budget before a single app name the
        // user was actually likely to say got in.
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.localizedName))
        let all = AppCatalog.shared.all.map(\.name)
        let apps = all.filter { running.contains($0) } + all.filter { !running.contains($0) }
        // The command phrases matter as much as the app names: "close tab" is
        // heard as "close thab" unless the recogniser is told it is likely.
        let phrases = Phrasebook.catalog()
        let verbs = ["toggle", "workspace", "scroll", "autofill", "approve", "deny",
                     "select all", "close tab", "close all tabs", "new tab", "go back"]
        // A browser task names a site and then says what to do there, and the
        // recogniser was never told either was likely. "Go to YouTube and
        // search …" is the commonest thing anyone says to this, so the sites
        // jev can actually start from, and the words that introduce a goal,
        // are worth their place in the budget.
        let web = WebStart.knownSites.map(\.spoken)
            + ["search for", "search", "play", "open the first result", "add to cart"]
        // Keystrokes are spoken, not listed anywhere, so the recogniser was
        // never told any of these words were likely. Measured: "press cmd 1"
        // came back as "prayers for man one". Every modifier, every digit and
        // the keys people name out loud now earn their place — a keystroke is
        // the most literal thing anyone says to this and the least forgiving
        // of a near-miss.
        let keys = ["press", "command", "cmd", "control", "option", "shift",
                    "escape", "enter", "return", "space", "delete", "tab"]
            // The whole shortcut, not the bare digit: "command 1" is a phrase
            // the recogniser can weigh, where "1" competes with every number
            // anyone might say and biases nothing in particular.
            + (1...9).map { "command \($0)" }

        // Deliberately far below what the API will take.
        //
        // This was 200. Apple's guidance is that biasing weakens as the list
        // grows — every extra phrase competes with the ones that matter — and
        // at 200 it had stopped defending even the words that were in it:
        // "new tab" is in `verbs` and still came back as "new dog". The cap
        // is now small enough that the phrases in it carry weight, and the
        // order decides what survives: what jev can actually do first, then
        // the apps that are running, then the rest.
        // Order is the budget. Small, high-value sets first, because
        // whatever falls off the end is not biased at all — and the first
        // version of this cap put `phrases` first, which ate every slot and
        // left the keystroke words out entirely. The assertions check that
        // the words this was built for actually survive.
        let hints = keys + verbs + web + phrases + apps
        var seen = Set<String>()
        let unique = hints.filter { seen.insert($0.lowercased()).inserted }
        return Array(unique.prefix(hintBudget))
    }

    /// How many phrases the recogniser is told to expect.
    static let hintBudget = 90

    /// Ask once for Speech Recognition. The result is remembered by macOS, so
    /// repeated launches are silent after the first approval.
    static func requestSpeechAuthorization() {
        #if canImport(Speech)
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else {
            JevLog.write("[allowly] speech recognition authorization: \(current.rawValue == 3 ? "granted" : String(describing: current))")
            return
        }
        SFSpeechRecognizer.requestAuthorization { status in
            JevLog.write("[allowly] speech recognition authorization now: \(String(describing: status))")
        }
        #endif
    }

    /// Apple Speech infers the container from the file extension, so an upload
    /// saved under the wrong one fails to decode. iOS Safari's MediaRecorder
    /// produces MP4/AAC despite the client naming the blob ".webm", so sniff
    /// the magic bytes instead of trusting either.
    static func fileExtension(forFirstBytesOf data: Data) -> String {
        let head = [UInt8](data.prefix(12))
        // "ftyp" at offset 4 marks the ISO base media format (MP4 / M4A).
        if head.count >= 8, head[4] == 0x66, head[5] == 0x74, head[6] == 0x79, head[7] == 0x70 {
            return "m4a"
        }
        // EBML header: WebM / Matroska. Apple Speech cannot read these.
        if head.count >= 4, head[0] == 0x1A, head[1] == 0x45, head[2] == 0xDF, head[3] == 0xA3 {
            return "webm"
        }
        if head.count >= 4, head[0] == 0x52, head[1] == 0x49, head[2] == 0x46, head[3] == 0x46 {
            return "wav"
        }
        return "m4a"
    }

    /// Apple Speech can only open containers AVFoundation understands, and
    /// Safari records WebM/Opus no matter what the client asks for. So anything
    /// that is not natively readable gets transcoded to 16 kHz mono WAV first.
    /// Returns nil when no transcoder is available.
    static func transcodeToWav(_ source: URL) -> URL? {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        guard let ffmpeg = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            JevLog.write("[allowly] voice: no ffmpeg found; cannot transcode \(source.pathExtension)")
            return nil
        }

        let output = source.deletingPathExtension().appendingPathExtension("wav")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        // 16 kHz mono PCM is what speech recognition wants anyway.
        process.arguments = [
            "-hide_banner", "-loglevel", "error", "-y",
            "-i", source.path,
            "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le",
            output.path,
        ]
        process.standardOutput = Pipe()
        let errPipe = Pipe()
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            JevLog.write("[allowly] voice: could not run ffmpeg: \(error)")
            return nil
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: output.path) else {
            let message = String(data: errData, encoding: .utf8) ?? "unknown"
            JevLog.write("[allowly] voice: ffmpeg failed: \(message.prefix(200))")
            return nil
        }
        return output
    }

    /// Formats AVFoundation opens directly, so no transcode is needed.
    static func isNativelyReadable(_ ext: String) -> Bool {
        ["m4a", "mp3", "wav", "aiff", "caf", "aac"].contains(ext)
    }
}
