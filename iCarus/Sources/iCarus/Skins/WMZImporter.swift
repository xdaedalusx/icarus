import Foundation

/// What we learned from looking inside a Windows Media Player skin.
struct WMPImportReport: Identifiable {
    struct ElementCount: Identifiable {
        enum Status: Int {
            case willConvert = 0   // a later import step will turn this into a widget
            case skipped = 1       // no equivalent in iCarus (yet)
            case structural = 2    // bookkeeping, nothing to draw
        }
        let tag: String
        let count: Int
        let status: Status
        var id: String { tag }
    }

    let id = UUID()
    var skinName: String
    var author: String?
    var copyright: String?
    var windowSize: (width: Int, height: Int)?
    var elements: [ElementCount] = []
    var fileCount = 0
    var imagesReferenced = 0
    var missingImages: [String] = []
    var scriptFiles: [String] = []
    var warnings: [String] = []
    // Piece 2
    var convertedImages: [WMPConvertedImage] = []
    var buttonGroups: [WMPButtonGroup] = []
}

/// Opens a .wmz skin (a zip archive) and reads its layout.
///
/// `inspect` only reads the file and reports. `buildSkin` converts it into an installable
/// iCarus skin folder (look only; controls come in a later piece).
enum WMZImporter {
    enum ImportError: LocalizedError {
        case notASkinFile
        case unzipFailed(String)
        case noLayoutFile
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .notASkinFile:
                return "That doesn't look like a .wmz skin file."
            case .unzipFailed(let detail):
                let text = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                return "The skin file couldn't be unpacked." + (text.isEmpty ? "" : " (\(text))")
            case .noLayoutFile:
                return "No .wms layout file was found inside. It may be a different kind of skin."
            case .tooLarge:
                return "The skin is unreasonably large once unpacked, so it was rejected."
            }
        }
    }

    struct ExtractedSkin {
        let folder: URL
        /// Paths relative to `folder`.
        let files: [String]
    }

    /// Elements a later piece will turn into widgets.
    static let convertible: Set<String> = [
        "view", "subview", "button", "buttongroup", "buttonelement",
        "playelement", "pauseelement", "stopelement", "prevelement", "nextelement",
        "seekslider", "volumeslider", "balanceslider", "slider",
        "text", "statustext", "currentpositiontext", "effects", "video",
        "progressbar", "customslider", "rewelement", "ffwdelement", "shuffleelement", "repeatelement"
    ]
    /// Elements that only organise or describe the skin.
    static let structural: Set<String> = ["theme", "player", "controls", "equalizersettings"]

    // MARK: Inspect

    static func inspect(archive: URL) async throws -> WMPImportReport {
        try await Task.detached(priority: .userInitiated) {
            try inspectNow(archive)
        }.value
    }

    private static func inspectNow(_ archive: URL) throws -> WMPImportReport {
        let ext = archive.pathExtension.lowercased()
        guard ["wmz", "wmd", "zip"].contains(ext) else { throw ImportError.notASkinFile }

        let extracted = try extract(archive)
        defer { try? FileManager.default.removeItem(at: extracted.folder) }

        guard let layoutPath = extracted.files
            .filter({ $0.lowercased().hasSuffix(".wms") })
            .min(by: { $0.count < $1.count }) else { throw ImportError.noLayoutFile }

        let data = try Data(contentsOf: extracted.folder.appendingPathComponent(layoutPath))
        let root = WMSParser.parse(decode(data))

        // Convert the artwork into a scratch folder (piece 3 will keep it and build the skin).
        let artworkFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("iCarus-wmz-art-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: artworkFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: artworkFolder) }
        let artwork = WMPArtwork.convert(layout: root, sourceFolder: extracted.folder,
                                         files: extracted.files, outputFolder: artworkFolder)

        var report = makeReport(name: archive.deletingPathExtension().lastPathComponent,
                                root: root,
                                files: extracted.files)
        report.convertedImages = artwork.images
        report.buttonGroups = artwork.buttonGroups
        report.warnings.append(contentsOf: artwork.problems)
        return report
    }


    // MARK: Build a skin (piece 3)

    struct BuiltFolder {
        /// A temporary folder holding skin.json and the PNGs. The caller installs it, then deletes it.
        let folder: URL
        let built: WMPBuiltSkin
    }

    /// Unpacks the archive, converts the artwork and writes a ready-to-install skin folder.
    static func buildSkin(archive: URL) async throws -> BuiltFolder {
        try await Task.detached(priority: .userInitiated) {
            try buildSkinNow(archive)
        }.value
    }

    private static func buildSkinNow(_ archive: URL) throws -> BuiltFolder {
        let ext = archive.pathExtension.lowercased()
        guard ["wmz", "wmd", "zip"].contains(ext) else { throw ImportError.notASkinFile }

        let extracted = try extract(archive)
        defer { try? FileManager.default.removeItem(at: extracted.folder) }

        guard let layoutPath = extracted.files
            .filter({ $0.lowercased().hasSuffix(".wms") })
            .min(by: { $0.count < $1.count }) else { throw ImportError.noLayoutFile }
        let data = try Data(contentsOf: extracted.folder.appendingPathComponent(layoutPath))
        let root = WMSParser.parse(decode(data))

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("iCarus-wmp-skin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        do {
            let artwork = WMPArtwork.convert(layout: root, sourceFolder: extracted.folder,
                                             files: extracted.files, outputFolder: output)
            let author = root.allNodes.first(where: { $0.tag == "theme" })?
                .attr("author")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let built = try WMPSkinBuilder.build(
                layout: root, artwork: artwork,
                name: archive.deletingPathExtension().lastPathComponent,
                author: (author?.isEmpty == false) ? author : nil,
                into: output)
            return BuiltFolder(folder: output, built: built)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    // MARK: Unzip

    /// Unpacks into a fresh temporary folder, then removes anything that points outside it.
    static func extract(_ archive: URL) throws -> ExtractedSkin {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory
            .appendingPathComponent("iCarus-wmz-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try runUnzip(archive, into: folder)
            return ExtractedSkin(folder: folder, files: try sanitize(folder))
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
    }

    private static func runUnzip(_ archive: URL, into folder: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")   // ships with macOS
        process.arguments = ["-o", "-q", archive.path, "-d", folder.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ImportError.unzipFailed(error.localizedDescription)
        }
        let detail = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // 0 = fine, 1 = finished with warnings (still usable).
        guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
            throw ImportError.unzipFailed(String(decoding: detail, as: UTF8.self))
        }
    }

    /// Deletes symlinks and anything that resolves outside the folder, and lists the real files.
    private static func sanitize(_ folder: URL) throws -> [String] {
        let fm = FileManager.default
        let rootPath = folder.resolvingSymlinksInPath().path
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: keys) else { return [] }

        var files: [String] = []
        var total = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { try? fm.removeItem(at: url); continue }

            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(rootPath + "/") else { try? fm.removeItem(at: url); continue }

            if values?.isRegularFile == true {
                files.append(String(path.dropFirst(rootPath.count + 1)))
                total += values?.fileSize ?? 0
            }
        }
        if total > 150_000_000 { throw ImportError.tooLarge }
        return files.sorted()
    }

    /// Old skins are often Latin-1; some are UTF-16.
    static func decode(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    // MARK: Report

    private static func makeReport(name: String, root: WMSNode, files: [String]) -> WMPImportReport {
        var report = WMPImportReport(skinName: name)
        report.fileCount = files.count
        let nodes = root.allNodes.filter { $0.tag != "#root" }

        func clean(_ text: String?) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        func number(_ text: String?) -> Int? {
            guard let text, let value = Double(text.trimmingCharacters(in: .whitespaces)) else { return nil }
            return Int(value)
        }

        if let theme = nodes.first(where: { $0.tag == "theme" }) {
            report.author = clean(theme.attr("author"))
            report.copyright = clean(theme.attr("copyright"))
        }

        let views = nodes.filter { $0.tag == "view" }
        if let view = views.first, let width = number(view.attr("width")), let height = number(view.attr("height")) {
            report.windowSize = (width, height)
        }

        // Element counts
        var counts: [String: Int] = [:]
        for node in nodes { counts[node.tag, default: 0] += 1 }
        report.elements = counts.map { tag, count in
            let status: WMPImportReport.ElementCount.Status =
                convertible.contains(tag) ? .willConvert : (structural.contains(tag) ? .structural : .skipped)
            return WMPImportReport.ElementCount(tag: tag, count: count, status: status)
        }.sorted {
            if $0.status.rawValue != $1.status.rawValue { return $0.status.rawValue < $1.status.rawValue }
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.tag < $1.tag
        }

        // Image files the layout refers to (any attribute ending in "image" that names a picture)
        let present = Set(files.map { ($0 as NSString).lastPathComponent.lowercased() })
        var referenced = Set<String>()
        var scriptExpressions = 0
        var builtInResources = 0
        for node in nodes {
            for (key, rawValue) in node.attributes {
                let value = rawValue.trimmingCharacters(in: .whitespaces)
                let lower = value.lowercased()
                if lower.hasPrefix("jscript:") { scriptExpressions += 1 }
                if lower.contains("res://") { builtInResources += 1 }
                guard key.hasSuffix("image"),
                      !lower.hasPrefix("jscript:"), !lower.hasPrefix("wmpprop:"), !lower.hasPrefix("res://"),
                      ["bmp", "gif", "jpg", "jpeg", "png"].contains((lower as NSString).pathExtension)
                else { continue }
                referenced.insert(value)
            }
        }
        report.imagesReferenced = referenced.count
        report.missingImages = referenced
            .filter { !present.contains(($0 as NSString).lastPathComponent.lowercased()) }
            .sorted()

        // Script files named by the view (the built-in res:// ones aren't in the archive)
        if let list = views.first?.attr("scriptfile") {
            report.scriptFiles = list.split(separator: ";")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.lowercased().hasPrefix("res://") }
        }

        // Heads-up messages
        if views.isEmpty {
            report.warnings.append("No <view> element was found, so the layout may use a format this importer doesn't know.")
        } else if views.count > 1 {
            report.warnings.append("This skin has \(views.count) views; only the first will be used.")
        }
        if !report.scriptFiles.isEmpty {
            report.warnings.append("Uses script (\(report.scriptFiles.joined(separator: ", "))). Scripted behaviour such as opening panes and animations won't carry over.")
        }
        if scriptExpressions > 0 {
            report.warnings.append("\(scriptExpressions) positions or sizes are calculated by script and may need adjusting.")
        }
        if builtInResources > 0 {
            report.warnings.append("References built-in Windows Media Player resources (res://…) that aren't available here.")
        }
        if !report.missingImages.isEmpty {
            report.warnings.append("\(report.missingImages.count) referenced image file(s) are missing from the archive.")
        }
        let skipped = report.elements.filter { $0.status == .skipped }
        if !skipped.isEmpty {
            let list = skipped.map { "\($0.tag) ×\($0.count)" }.joined(separator: ", ")
            report.warnings.append("Not supported yet and will be skipped: \(list).")
        }
        return report
    }
}
