import SwiftUI
import UniformTypeIdentifiers

/// The main window. Picks a layout based on the active skin and wires up
/// file opening and drag-and-drop, which are the same for every skin.
struct PlayerView: View {
    @EnvironmentObject private var engine: PlayerEngine
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.skin) private var skin
    @State private var showingImporter = false

    var body: some View {
        ZStack {
            skin.background.ignoresSafeArea()

            if let image = skin.backgroundImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .opacity(0.35)
                    .clipped()
            }

            switch skin.manifest.layout {
            case .standard: StandardLayout()
            case .compact: CompactLayout()
            }
        }
        .frame(width: skin.manifest.metrics.windowWidth,
               height: skin.manifest.metrics.windowHeight)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingImporter = true
                } label: {
                    Label("Add Files", systemImage: "plus")
                }
                .keyboardShortcut("o", modifiers: .command)
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
        }
        .fileImporter(
            isPresented: $showingImporter,
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
