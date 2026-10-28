import Foundation
import AppKit

/// Only formats the player can reliably play are offered.
/// (YouTube's native "original" audio is usually Opus, which AVPlayer can't play.)
enum AudioFormat: String, CaseIterable, Identifiable {
    case mp3, m4a, mp4   // mp4 = video (H.264 + AAC, which the player can show)

    var id: String { rawValue }
    var label: String {
        switch self {
        case .mp3: return "MP3"
        case .m4a: return "M4A"
        case .mp4: return "Video"
        }
    }
}

struct DownloadedItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var name: String { url.deletingPathExtension().lastPathComponent }
}

/// Runs yt-dlp as a child process and reports progress.
@MainActor
final class DownloadManager: ObservableObject {
    // MARK: Inputs
    @Published var urlText = ""
    @Published var folder: URL {
        didSet { UserDefaults.standard.set(folder.path, forKey: Keys.folder) }
    }
    @Published var format: AudioFormat {
        didSet { UserDefaults.standard.set(format.rawValue, forKey: Keys.format) }
    }
    @Published var skipExisting: Bool {
        didSet { UserDefaults.standard.set(skipExisting, forKey: Keys.skip) }
    }
    @Published var singleOnly: Bool {
        didSet { UserDefaults.standard.set(singleOnly, forKey: Keys.single) }
    }

    // MARK: Outputs
    @Published private(set) var isRunning = false
    @Published private(set) var progress: Double?
    @Published private(set) var statusText = "Paste a link to get started."
    @Published private(set) var log: [String] = []
    @Published private(set) var completed: [DownloadedItem] = []
    @Published private(set) var setupProblem: String?

    /// Called for every finished file so the player can add it to its library.
    var onFileReady: ((URL) -> Void)?

    private enum Keys {
        static let folder = "downloadFolder"
        static let format = "downloadFormat"
        static let skip = "downloadSkipExisting"
        static let single = "downloadSingleOnly"
    }

    private var process: Process?
    private var wasCancelled = false
    private var itemPrefix = ""
    private var skippedCount = 0

    private static let searchPaths = [
        "/opt/homebrew/bin", "/usr/local/bin",
        NSHomeDirectory() + "/.local/bin", "/usr/bin"
    ]

    init() {
        let defaults = UserDefaults.standard
        let defaultFolder = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iCarus", isDirectory: true)

        if let saved = defaults.string(forKey: Keys.folder) {
            folder = URL(fileURLWithPath: saved, isDirectory: true)
        } else {
            folder = defaultFolder
        }
        format = AudioFormat(rawValue: defaults.string(forKey: Keys.format) ?? "") ?? .mp3
        skipExisting = defaults.object(forKey: Keys.skip) as? Bool ?? true
        singleOnly = defaults.object(forKey: Keys.single) as? Bool ?? true
        refreshTools()
    }

    // MARK: Tool discovery
    private static func findExecutable(_ name: String) -> String? {
        searchPaths
            .map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func refreshTools() {
        var missing: [String] = []
        if Self.findExecutable("yt-dlp") == nil { missing.append("yt-dlp") }
        if Self.findExecutable("ffmpeg") == nil { missing.append("ffmpeg") }
        setupProblem = missing.isEmpty
            ? nil
            : "Missing \(missing.joined(separator: " and ")). Install with:  brew install \(missing.joined(separator: " "))"
    }

    func pasteFromClipboard() {
        if let text = NSPasteboard.general.string(forType: .string) {
            urlText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: Start / stop
    func start() {
        guard !isRunning else { return }
        refreshTools()
        guard setupProblem == nil, let ytdlp = Self.findExecutable("yt-dlp") else {
            statusText = "Set up yt-dlp and ffmpeg first."
            return
        }

        let link = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            statusText = "That doesn't look like a valid link."
            return
        }

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            statusText = "Can't create the folder: \(error.localizedDescription)"
            return
        }

        var args = ["--newline", "--no-colors", "--progress"]
        switch format {
        case .mp3:
            args += ["-x", "--audio-format", "mp3", "--audio-quality", "0"]
        case .m4a:
            args += ["-x", "--audio-format", "m4a"]
        case .mp4:
            // Prefer H.264 + AAC so AVFoundation can play both picture and sound.
            args += ["-f", "bv*[vcodec^=avc1]+ba[ext=m4a]/b[ext=mp4]/b",
                     "--merge-output-format", "mp4"]
        }
        args += ["--embed-metadata", "--embed-thumbnail",
                 "--print", "after_move:filepath", "--no-quiet",
                 "-o", folder.appendingPathComponent("%(title)s.%(ext)s").path]
        if singleOnly { args.append("--no-playlist") }
        if skipExisting {
            args += ["--download-archive", folder.appendingPathComponent(".downloaded.txt").path]
        }
        args.append(link)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ytdlp)
        proc.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.searchPaths.joined(separator: ":") + ":" + (env["PATH"] ?? "")
        proc.environment = env
        proc.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        process = proc
        wasCancelled = false
        isRunning = true
        progress = nil
        itemPrefix = ""
        skippedCount = 0
        log = []
        completed = []
        statusText = "Starting…"

        Task {
            do {
                try proc.run()
            } catch {
                finish(status: -1, message: "Couldn't launch yt-dlp: \(error.localizedDescription)")
                return
            }
            do {
                for try await line in pipe.fileHandleForReading.bytes.lines {
                    handle(line: line)
                }
            } catch {
                // Stream ended unexpectedly; fall through to wait for exit.
            }
            let status = await Task.detached {
                proc.waitUntilExit()
                return proc.terminationStatus
            }.value
            finish(status: status, message: nil)
        }
    }

    func stop() {
        wasCancelled = true
        process?.terminate()
    }

    // MARK: Output handling
    private func handle(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        log.append(trimmed)
        if log.count > 500 { log.removeFirst(log.count - 500) }

        // A finished file path printed by --print after_move:filepath
        if trimmed.hasPrefix("/"), FileManager.default.fileExists(atPath: trimmed) {
            let fileURL = URL(fileURLWithPath: trimmed)
            completed.append(DownloadedItem(url: fileURL))
            statusText = "Saved \(fileURL.deletingPathExtension().lastPathComponent)"
            onFileReady?(fileURL)
            return
        }

        if trimmed.contains("Downloading item") {
            // "[download] Downloading item 3 of 10"
            let parts = trimmed.components(separatedBy: " ")
            if let i = parts.firstIndex(of: "item"), parts.count > i + 3 {
                itemPrefix = "Track \(parts[i + 1]) of \(parts[i + 3]) · "
            }
            progress = nil
            return
        }

        if trimmed.contains("has already been recorded in the archive") {
            skippedCount += 1
            statusText = "Skipping a song you already have…"
            return
        }

        if trimmed.hasPrefix("[download]"),
           let range = trimmed.range(of: #"\d+(\.\d+)?%"#, options: .regularExpression),
           let value = Double(trimmed[range].dropLast()) {
            progress = value / 100
            statusText = "\(itemPrefix)Downloading… \(Int(value))%"
            return
        }

        if trimmed.hasPrefix("[ExtractAudio]") || trimmed.hasPrefix("[Metadata]") || trimmed.hasPrefix("[EmbedThumbnail]") {
            statusText = "\(itemPrefix)Converting and tagging…"
            progress = nil
        }
    }

    private func finish(status: Int32, message: String?) {
        isRunning = false
        process = nil
        progress = nil

        if let message {
            statusText = message
        } else if wasCancelled {
            statusText = "Stopped."
        } else if status == 0 {
            let n = completed.count
            var text = n == 0 ? "Nothing new to download." : "Done. Added \(n) song\(n == 1 ? "" : "s")."
            if skippedCount > 0 { text += " Skipped \(skippedCount) already downloaded." }
            statusText = text
        } else if completed.isEmpty {
            statusText = "Download failed. Check the log below. If it keeps failing, update yt-dlp (brew upgrade yt-dlp)."
        } else {
            statusText = "Finished with some errors. Added \(completed.count) song\(completed.count == 1 ? "" : "s")."
        }
    }
}
