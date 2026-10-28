import Foundation
import AVFoundation

struct Track: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var title: String
    var artist: String
    /// True when the file has a video track (shown in the video pane).
    var hasVideo = false

    /// Builds a track, reading title/artist metadata when available.
    static func load(from url: URL) async -> Track {
        var title = url.deletingPathExtension().lastPathComponent
        var artist = ""

        let asset = AVURLAsset(url: url)
        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                guard let key = item.commonKey else { continue }
                if key == .commonKeyTitle,
                   let value = try? await item.load(.stringValue), !value.isEmpty {
                    title = value
                } else if key == .commonKeyArtist,
                          let value = try? await item.load(.stringValue), !value.isEmpty {
                    artist = value
                }
            }
        }
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        return Track(url: url, title: title, artist: artist, hasVideo: !videoTracks.isEmpty)
    }
}

enum RepeatMode: String, CaseIterable {
    case off, all, one

    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }

    var symbol: String {
        self == .one ? "repeat.1" : "repeat"
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds)
    return String(format: "%d:%02d", total / 60, total % 60)
}
