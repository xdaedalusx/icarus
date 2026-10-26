import Foundation

/// Finds playable audio files on disk (used to fill the player from the downloads folder).
enum LibraryScanner {
    // Formats AVPlayer can reliably play on macOS.
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "flac", "caf"]

    static func audioFiles(in folder: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [(url: URL, date: Date)] = []
        for case let url as URL in enumerator {
            guard audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            files.append((url, values?.contentModificationDate ?? .distantPast))
        }
        // Newest downloads first.
        return files.sorted { $0.date > $1.date }.map(\.url)
    }
}
