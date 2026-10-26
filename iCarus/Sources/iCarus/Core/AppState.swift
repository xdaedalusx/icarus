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
}
