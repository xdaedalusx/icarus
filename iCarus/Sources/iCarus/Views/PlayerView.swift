import SwiftUI
import UniformTypeIdentifiers

/// The main window. Picks a layout based on the active skin and wires up
/// file opening and drag-and-drop, which are the same for every skin.
struct PlayerView: View {
    @EnvironmentObject private var engine: PlayerEngine
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var appState: AppState
    @Environment(\.skin) private var skin

    var body: some View {
        ZStack {
            if !skin.isShaped { skin.background.ignoresSafeArea() }

            if !skin.isShaped, let image = skin.backgroundImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .opacity(0.35)
                    .clipped()
            }

            switch skin.manifest.layout {
            case .standard: StandardLayout()
            case .compact: CompactLayout()
            case .widgets:
                if let layout = skin.manifest.widgets {
                    WidgetCanvas(layout: layout).padding(skin.isShaped ? 0 : 8)
                } else {
                    StandardLayout()
                }
            }
        }
        .frame(width: skin.manifest.metrics.windowWidth,
               height: skin.manifest.metrics.windowHeight)
        .ignoresSafeArea(edges: skin.isShaped ? .all : [])
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.showingImporter = true
                } label: {
                    Label("Add Files", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    engine.add(urls: LibraryScanner.audioFiles(in: downloads.folder),
                               autoplay: false)
                } label: {
                    Label("Load Downloads", systemImage: "arrow.clockwise")
                }
                .help("Add any songs in your downloads folder")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.showingEQ = true
                } label: {
                    Label("Equalizer", systemImage: "slider.vertical.3")
                }
                .help("Equalizer (⌘E)")
            }
        }
        .sheet(isPresented: $appState.showingEQ) {
            EqualizerView()
        }
        .sheet(isPresented: $appState.showingPlaylist) {
            PlaylistSheet()
        }
        .overlay(alignment: .bottom) {
            if let message = engine.errorMessage {
                Text(message)
                    .font(skin.bodyFont)
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                    .padding(8)
                    .onTapGesture { engine.clearError() }
            }
        }
        .fileImporter(
            isPresented: $appState.showingImporter,
            allowedContentTypes: [.audio, .movie],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { engine.add(urls: urls) }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .preferredColorScheme(.dark)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in engine.add(urls: [url]) }
            }
        }
        return accepted
    }
}

/// The playlist in its own window, for skins that don't have room for one.
struct PlaylistSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.skin) private var skin

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Playlist").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            PlaylistView()
        }
        .frame(width: 380, height: 440)
        .background(skin.isShaped ? Color(nsColor: .windowBackgroundColor) : skin.background)
    }
}
