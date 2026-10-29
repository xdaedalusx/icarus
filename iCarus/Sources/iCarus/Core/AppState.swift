import Foundation

/// The two top-level modes of the app.
enum AppSection: String, CaseIterable, Identifiable {
    case play = "Play"
    case get = "Get"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .play: return "play.circle"
        case .get: return "arrow.down.circle"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var section: AppSection = .play
    /// Driven by menu commands so they work even when the toolbar is hidden (shaped skins).
    @Published var showingImporter = false
    @Published var showingEQ = false
    @Published var showingPlaylist = false
}
