import SwiftUI

/// Get's "Advanced" tab: more of yt-dlp's options, with a preview of the exact command.
struct GetAdvancedView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.skin) private var skin

    var body: some View {
        let options = $downloads.advanced
        let isVideo = downloads.format == .mp4

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("Quality") {
                    if isVideo {
                        row("Video size") {
                            Picker("", selection: options.videoHeight) {
                                ForEach(AdvancedOptions.VideoHeight.allCases) { Text($0.label).tag($0) }
                            }
                            .frame(width: 140)
                        }
                    } else {
                        row("Audio quality") {
                            Picker("", selection: options.audioQuality) {
                                ForEach(AdvancedOptions.AudioQuality.allCases) { Text($0.label).tag($0) }
                            }
                            .frame(width: 140)
                        }
                    }
                }

                section("Files") {
                    row("Name files as") {
                        Picker("", selection: options.nameStyle) {
                            ForEach(AdvancedOptions.NameStyle.allCases) { Text($0.label).tag($0) }
                        }
                        .frame(width: 210)
                    }
                    if downloads.advanced.nameStyle == .custom {
                        TextField("%(artist)s - %(title)s", text: options.customTemplate)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                        Text("yt-dlp output template. Fields: title, artist, uploader, album, upload_date, playlist_index.")
                            .note(skin)
                    }
                    Toggle("Plain file names (no accents, spaces or symbols)", isOn: options.restrictFilenames)
                }

                section("Tags and cover art") {
                    Toggle("Embed the thumbnail as cover art", isOn: options.embedThumbnail)
                    Toggle("Embed title, artist and other info", isOn: options.embedMetadata)
                    Toggle("Split \"Artist - Title\" video titles into artist and title",
                           isOn: options.splitArtistTitle)
                }

                section("Playlists") {
                    row("Only these items") {
                        TextField("e.g. 1-5,8", text: options.playlistItems)
                            .textFieldStyle(.roundedBorder).frame(width: 140)
                    }
                    Toggle("Start from the end of the playlist", isOn: options.playlistReverse)
                    if downloads.singleOnly {
                        Text("These only apply when \"Only this video\" is turned off on the Basic tab.")
                            .note(skin)
                    }
                }

                section("Just part of it") {
                    HStack(spacing: 8) {
                        Text("From").foregroundStyle(skin.secondaryText)
                        TextField("0:00", text: options.trimStart)
                            .textFieldStyle(.roundedBorder).frame(width: 80)
                        Text("to").foregroundStyle(skin.secondaryText)
                        TextField("end", text: options.trimEnd)
                            .textFieldStyle(.roundedBorder).frame(width: 80)
                    }
                    Toggle("Cut exactly at those times (slower)", isOn: options.preciseCuts)
                }

                section("Clean up") {
                    Text("Cut these out (YouTube only):").foregroundStyle(skin.secondaryText)
                    ForEach(AdvancedOptions.sponsorChoices, id: \.id) { choice in
                        Toggle(choice.label, isOn: Binding(
                            get: { downloads.advanced.sponsorCategories.contains(choice.id) },
                            set: { on in
                                if on { downloads.advanced.sponsorCategories.insert(choice.id) }
                                else { downloads.advanced.sponsorCategories.remove(choice.id) }
                            }))
                    }
                    Toggle("Embed subtitles (video only)", isOn: options.embedSubtitles)
                        .disabled(!isVideo)
                    if downloads.advanced.embedSubtitles && isVideo {
                        row("Languages") {
                            TextField("en", text: options.subtitleLanguages)
                                .textFieldStyle(.roundedBorder).frame(width: 140)
                        }
                    }
                }

                section("Access and speed") {
                    row("Use cookies from") {
                        Picker("", selection: options.cookiesBrowser) {
                            ForEach(AdvancedOptions.Browser.allCases) { Text($0.label).tag($0) }
                        }
                        .frame(width: 140)
                    }
                    Text("For age-restricted or members-only videos. macOS may ask permission to read the browser.")
                        .note(skin)
                    row("Speed limit") {
                        TextField("e.g. 2M", text: options.rateLimit)
                            .textFieldStyle(.roundedBorder).frame(width: 100)
                    }
                }

                section("More yt-dlp options") {
                    TextField("--embed-chapters --retries 10", text: options.extraArguments)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    Text("Added to the end of the command. Options that run other programs (like --exec) are blocked.")
                        .note(skin)
                }

                section("Command") {
                    Text(downloads.commandPreview())
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(skin.secondaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(skin.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: skin.cornerRadius))
                    if let problem = downloads.advanced.problem() {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    HStack {
                        Button("Copy Command") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(downloads.commandPreview(), forType: .string)
                        }
                        Button("Reset to Defaults") { downloads.advanced = AdvancedOptions() }
                    }
                    .controlSize(.small)
                }
            }
            .font(skin.bodyFont)
            .foregroundStyle(skin.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 6)
        }
        .disabled(downloads.isRunning)
    }

    // MARK: Layout helpers

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(skin.bodyFont.weight(.semibold))
            content()
        }
    }

    private func row<Content: View>(_ label: String,
                                    @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label).foregroundStyle(skin.secondaryText).frame(width: 110, alignment: .leading)
            content()
        }
    }
}

private extension Text {
    func note(_ skin: Skin) -> some View {
        self.font(.caption).foregroundStyle(skin.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}
