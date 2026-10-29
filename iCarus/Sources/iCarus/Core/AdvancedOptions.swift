import Foundation

/// The extra yt-dlp settings on Get's Advanced tab. Everything here has a default that
/// reproduces the app's normal behaviour, so leaving the tab alone changes nothing.
struct AdvancedOptions: Codable, Equatable {
    enum AudioQuality: String, Codable, CaseIterable, Identifiable {
        case best, k320, k256, k192, k128
        var id: String { rawValue }
        var label: String {
            switch self {
            case .best: return "Best"
            case .k320: return "320 kbps"
            case .k256: return "256 kbps"
            case .k192: return "192 kbps"
            case .k128: return "128 kbps"
            }
        }
        /// Value for --audio-quality (0 = best VBR, or a bitrate).
        var flag: String {
            switch self {
            case .best: return "0"
            case .k320: return "320K"
            case .k256: return "256K"
            case .k192: return "192K"
            case .k128: return "128K"
            }
        }
    }

    enum VideoHeight: String, Codable, CaseIterable, Identifiable {
        case best, p1080 = "1080", p720 = "720", p480 = "480", p360 = "360"
        var id: String { rawValue }
        var label: String { self == .best ? "Best" : "\(rawValue)p" }
    }

    enum NameStyle: String, Codable, CaseIterable, Identifiable {
        case title, artistTitle, indexTitle, channelFolder, custom
        var id: String { rawValue }
        var label: String {
            switch self {
            case .title: return "Title"
            case .artistTitle: return "Artist - Title"
            case .indexTitle: return "Playlist number - Title"
            case .channelFolder: return "Channel folder / Title"
            case .custom: return "Custom…"
            }
        }
        var template: String? {
            switch self {
            case .title: return "%(title)s"
            case .artistTitle: return "%(artist,uploader)s - %(title)s"
            case .indexTitle: return "%(playlist_index&{} - |)s%(title)s"
            case .channelFolder: return "%(uploader)s/%(title)s"
            case .custom: return nil
            }
        }
    }

    enum Browser: String, Codable, CaseIterable, Identifiable {
        case none, safari, chrome, firefox, brave, edge
        var id: String { rawValue }
        var label: String { self == .none ? "None" : rawValue.capitalized }
    }

    /// SponsorBlock categories that can be cut out (YouTube only).
    static let sponsorChoices: [(id: String, label: String)] = [
        ("music_offtopic", "Non-music parts (music videos)"),
        ("sponsor", "Sponsor segments"),
        ("selfpromo", "Self-promotion"),
        ("intro", "Intros"),
        ("outro", "Outros / end cards"),
        ("interaction", "\"Like and subscribe\" reminders")
    ]

    // Quality
    var audioQuality = AudioQuality.best
    var videoHeight = VideoHeight.best
    // Files
    var nameStyle = NameStyle.title
    var customTemplate = "%(title)s"
    var restrictFilenames = false
    // Tags
    var embedThumbnail = true
    var embedMetadata = true
    var splitArtistTitle = false
    // Playlists
    var playlistItems = ""
    var playlistReverse = false
    // Trim
    var trimStart = ""
    var trimEnd = ""
    var preciseCuts = false
    // Clean up
    var sponsorCategories: Set<String> = []
    var embedSubtitles = false
    var subtitleLanguages = "en"
    // Access
    var cookiesBrowser = Browser.none
    var rateLimit = ""
    // Anything else
    var extraArguments = ""

    // MARK: Checking

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static let timePattern = #"^\d+(:\d{1,2}){0,2}(\.\d+)?$"#

    /// The first thing wrong with these settings, or nil if they're fine.
    func problem() -> String? {
        let items = playlistItems.trimmingCharacters(in: .whitespaces)
        if !items.isEmpty, !Self.matches(items, #"^[0-9,:\- ]+$"#) {
            return "Playlist items should look like 1-5,8 (numbers, commas, dashes)."
        }
        for (name, value) in [("Trim start", trimStart), ("Trim end", trimEnd)] {
            let text = value.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty, !Self.matches(text, Self.timePattern) {
                return "\(name) should be a time like 1:30 or 90."
            }
        }
        let limit = rateLimit.trimmingCharacters(in: .whitespaces)
        if !limit.isEmpty, !Self.matches(limit, #"^\d+(\.\d+)?[KkMm]?$"#) {
            return "Speed limit should look like 500K or 2M."
        }
        if embedSubtitles, !Self.matches(subtitleLanguages.trimmingCharacters(in: .whitespaces),
                                         #"^[A-Za-z0-9_,.*\-]+$"#) {
            return "Subtitle languages should look like en or en,es."
        }
        if nameStyle == .custom {
            let template = customTemplate.trimmingCharacters(in: .whitespaces)
            if template.isEmpty { return "The file name template is empty." }
            if template.hasPrefix("/") || template.hasPrefix("~") || template.contains("..") {
                return "The file name template must stay inside the save folder."
            }
        }
        switch Self.tokens(extraArguments) {
        case .failure: return "Extra options have an unclosed quote."
        case .success(let list):
            for token in list {
                let name = token.split(separator: "=", maxSplits: 1).first.map(String.init) ?? token
                if Self.blockedFlags.contains(name) {
                    return "\(name) isn't allowed here, because it runs other programs."
                }
            }
        }
        return nil
    }

    /// Options that make yt-dlp run arbitrary commands; left out on purpose.
    private static let blockedFlags: Set<String> = [
        "--exec", "--exec-before-download", "--netrc-cmd", "--external-downloader",
        "--downloader", "--external-downloader-args", "--downloader-args", "--plugin-dirs", "--config-locations"
    ]

    // MARK: Arguments

    /// The output template (relative to the save folder, without the extension).
    var template: String {
        nameStyle.template ?? customTemplate.trimmingCharacters(in: .whitespaces)
    }

    /// Which pictures and sounds to fetch.
    func formatArguments(for format: AudioFormat) -> [String] {
        switch format {
        case .mp3:
            return ["-x", "--audio-format", "mp3", "--audio-quality", audioQuality.flag]
        case .m4a:
            var args = ["-x", "--audio-format", "m4a"]
            if audioQuality != .best { args += ["--audio-quality", audioQuality.flag] }
            return args
        case .mp4:
            // Prefer H.264 + AAC so the player can show both picture and sound.
            if videoHeight == .best {
                return ["-f", "bv*[vcodec^=avc1]+ba[ext=m4a]/b[ext=mp4]/b", "--merge-output-format", "mp4"]
            }
            let h = videoHeight.rawValue
            return ["-f", "bv*[height<=\(h)][vcodec^=avc1]+ba[ext=m4a]/b[height<=\(h)][ext=mp4]/b[height<=\(h)]",
                    "--merge-output-format", "mp4"]
        }
    }

    /// Everything else on this tab.
    func extraFlags(format: AudioFormat, singleOnly: Bool) -> [String] {
        var args: [String] = []
        if restrictFilenames { args.append("--restrict-filenames") }
        if splitArtistTitle { args += ["--parse-metadata", "title:%(artist)s - %(title)s"] }
        if embedMetadata { args.append("--embed-metadata") }
        if embedThumbnail {
            // YouTube thumbnails are WebP, which can't be embedded reliably; convert to JPG first.
            args += ["--embed-thumbnail", "--convert-thumbnails", "jpg"]
        }

        let items = playlistItems.trimmingCharacters(in: .whitespaces)
        if !singleOnly {
            if !items.isEmpty { args += ["--playlist-items", items.replacingOccurrences(of: " ", with: "")] }
            if playlistReverse { args.append("--playlist-reverse") }
        }

        let start = trimStart.trimmingCharacters(in: .whitespaces)
        let end = trimEnd.trimmingCharacters(in: .whitespaces)
        if !start.isEmpty || !end.isEmpty {
            args += ["--download-sections", "*\(start.isEmpty ? "0" : start)-\(end.isEmpty ? "inf" : end)"]
            if preciseCuts { args.append("--force-keyframes-at-cuts") }
        }

        if !sponsorCategories.isEmpty {
            args += ["--sponsorblock-remove", sponsorCategories.sorted().joined(separator: ",")]
        }
        if embedSubtitles, format == .mp4 {
            args += ["--write-subs", "--write-auto-subs", "--embed-subs",
                     "--sub-langs", subtitleLanguages.trimmingCharacters(in: .whitespaces)]
        }
        if cookiesBrowser != .none { args += ["--cookies-from-browser", cookiesBrowser.rawValue] }
        let limit = rateLimit.trimmingCharacters(in: .whitespaces)
        if !limit.isEmpty { args += ["--limit-rate", limit] }

        if case .success(let list) = Self.tokens(extraArguments) { args += list }
        return args
    }

    // MARK: Splitting extra options

    /// Splits text into arguments the way a shell would (spaces, 'single' and "double" quotes).
    /// Nothing is ever run through a shell; these go straight to yt-dlp.
    static func tokens(_ text: String) -> Result<[String], TokenError> {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var started = false
        for ch in text {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "'" || ch == "\"" {
                quote = ch; started = true
            } else if ch.isWhitespace {
                if started { result.append(current); current = ""; started = false }
            } else {
                current.append(ch); started = true
            }
        }
        if quote != nil { return .failure(.unclosedQuote) }
        if started { result.append(current) }
        return .success(result)
    }

    enum TokenError: Error { case unclosedQuote }
}
