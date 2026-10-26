import SwiftUI

/// The "Get" section: paste a YouTube link, download it with yt-dlp,
/// and the finished songs appear in Play.
struct GetView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var engine: PlayerEngine
    @EnvironmentObject private var appState: AppState
    @Environment(\.skin) private var skin

    @State private var choosingFolder = false
    @State private var showLog = false

    var body: some View {
        ZStack {
            skin.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: skin.spacing) {
                header
                if let problem = downloads.setupProblem { setupBanner(problem) }
                linkRow
                options
                actionRow
                statusArea
                completedList
                logSection
            }
            .padding(skin.spacing * 1.4)
        }
        .frame(width: 520, height: 640)
        .preferredColorScheme(.dark)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { downloads.folder = url }
        }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Get Music")
                .font(skin.titleFont)
                .foregroundStyle(skin.text)
            Text("Paste a YouTube link. Songs are saved and added to Play automatically.")
                .font(skin.bodyFont)
                .foregroundStyle(skin.secondaryText)
        }
    }

    private func setupBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(skin.bodyFont)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
            Button("Check Again") { downloads.refreshTools() }
                .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: skin.cornerRadius))
    }

    private var linkRow: some View {
        HStack {
            TextField("https://www.youtube.com/…", text: $downloads.urlText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { downloads.start() }
                .disabled(downloads.isRunning)
            Button {
                downloads.pasteFromClipboard()
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .help("Paste from clipboard")
            .disabled(downloads.isRunning)
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Save to")
                    .foregroundStyle(skin.secondaryText)
                Text(downloads.folder.path)
                    .foregroundStyle(skin.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose…") { choosingFolder = true }
                Button("Reveal") { NSWorkspace.shared.open(downloads.folder) }
            }
            .font(skin.bodyFont)

            HStack {
                Text("Format")
                    .foregroundStyle(skin.secondaryText)
                    .font(skin.bodyFont)
                Picker("Format", selection: $downloads.format) {
                    ForEach(AudioFormat.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
            }

            Toggle("Skip songs I've already downloaded", isOn: $downloads.skipExisting)
            Toggle("Only this video (not the whole playlist)", isOn: $downloads.singleOnly)
        }
        .font(skin.bodyFont)
        .foregroundStyle(skin.text)
        .disabled(downloads.isRunning)
    }

    private var actionRow: some View {
        HStack {
            Button {
                downloads.start()
            } label: {
                Label("Download", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(skin.accent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(downloads.isRunning
                      || downloads.urlText.trimmingCharacters(in: .whitespaces).isEmpty)

            if downloads.isRunning {
                Button("Stop") { downloads.stop() }
            }
        }
    }

    private var statusArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            if downloads.isRunning {
                ProgressView(value: downloads.progress)
                    .tint(skin.accent)
            }
            Text(downloads.statusText)
                .font(skin.bodyFont)
                .foregroundStyle(skin.secondaryText)
        }
    }

    private var completedList: some View {
        Group {
            if downloads.completed.isEmpty {
                Spacer(minLength: 0)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Added to your library")
                        .font(skin.bodyFont.weight(.semibold))
                        .foregroundStyle(skin.text)
                    List(downloads.completed) { item in
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(skin.accent)
                            Text(item.name)
                                .lineLimit(1)
                                .foregroundStyle(skin.text)
                            Spacer()
                            Button("Play") {
                                engine.addAndPlay(url: item.url)
                                appState.section = .play
                            }
                            .controlSize(.small)
                        }
                        .font(skin.bodyFont)
                    }
                    .scrollContentBackground(.hidden)
                    .background(skin.surface.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: skin.cornerRadius))
                }
            }
        }
    }

    private var logSection: some View {
        DisclosureGroup("Details", isExpanded: $showLog) {
            ScrollView {
                Text(downloads.log.suffix(120).joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(skin.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 110)
        }
        .font(skin.bodyFont)
        .foregroundStyle(skin.secondaryText)
    }
}
