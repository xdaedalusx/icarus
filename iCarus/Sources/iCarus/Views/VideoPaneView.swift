import SwiftUI
import AVFoundation
import AppKit

/// Hosts an AVPlayerLayer. Sized by SwiftUI; the picture is letterboxed to fit.
final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

/// The video pane: shows the picture when the current track has video,
/// and a quiet placeholder otherwise. Fill whatever frame it's given.
struct VideoPaneView: View {
    @EnvironmentObject private var engine: PlayerEngine

    var body: some View {
        // Observe the video controller directly so the pane updates when it changes.
        VideoPaneContent(video: engine.video)
    }
}

private struct VideoPaneContent: View {
    @ObservedObject var video: VideoController
    @EnvironmentObject private var engine: PlayerEngine
    @Environment(\.skin) private var skin

    var body: some View {
        ZStack {
            Color.black
            if video.isActive {
                VideoSurface(player: video.player)
            } else if let artwork = engine.currentTrack?.artwork {
                GeometryReader { geo in
                    Image(nsImage: artwork)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
            } else {
                Image(systemName: "film")
                    .font(.system(size: 28))
                    .foregroundStyle(skin.secondaryText.opacity(0.6))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: skin.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: skin.cornerRadius)
                .stroke(skin.secondaryText.opacity(0.4), lineWidth: 1)
        )
    }
}

/// Widget wrapper so a skin can place the video pane on its canvas.
/// (Ignores its binding.)
struct VideoPaneWidget: View {
    let spec: WidgetSpec
    @EnvironmentObject private var engine: PlayerEngine

    var body: some View {
        if spec.bare == true {
            // The skin's own artwork supplies the screen; only the picture itself is drawn.
            BareVideo(video: engine.video)
                .frame(width: spec.width, height: spec.height)
                .allowsHitTesting(false)
        } else {
            VideoPaneView()
                .frame(width: spec.width, height: spec.height)
        }
    }
}

private struct BareVideo: View {
    @ObservedObject var video: VideoController
    @EnvironmentObject private var engine: PlayerEngine

    var body: some View {
        if video.isActive {
            VideoSurface(player: video.player)
        } else if let artwork = engine.currentTrack?.artwork {
            // No video: show the song's cover art / thumbnail in the skin's screen.
            GeometryReader { geo in
                Image(nsImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }
        } else {
            Color.clear
        }
    }
}
