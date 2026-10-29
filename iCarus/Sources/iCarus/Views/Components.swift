import SwiftUI

// Reusable building blocks. Every layout assembles these, so a new layout
// is just a different arrangement of the same controls.

struct NowPlayingInfo: View {
    @EnvironmentObject private var engine: PlayerEngine
    @Environment(\.skin) private var skin
    var alignment: HorizontalAlignment = .center

    var body: some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(engine.currentTrack?.title ?? "Nothing playing")
                .font(skin.titleFont)
                .foregroundStyle(skin.text)
                .lineLimit(1)
            Text(engine.currentTrack?.artist.isEmpty == false
                 ? engine.currentTrack!.artist : " ")
                .font(skin.bodyFont)
                .foregroundStyle(skin.secondaryText)
                .lineLimit(1)
        }
    }
}

struct ArtworkPlaceholder: View {
    @EnvironmentObject private var engine: PlayerEngine
    @Environment(\.skin) private var skin
    /// "bars", "waveform", "radial" or "off". Click the square to cycle.
    @AppStorage("visualizerStyle") private var styleRaw = VisualizerStyle.bars.rawValue

    private var showsVideo: Bool { engine.currentTrack?.hasVideo == true }
    private var artwork: NSImage? { showsVideo ? nil : engine.currentTrack?.artwork }

    /// The picture's shape, kept between square and widescreen so nothing is cropped too hard.
    private var frameRatio: CGFloat {
        if showsVideo { return 16.0 / 9.0 }
        guard let size = artwork?.size, size.height > 0 else { return 1 }
        return min(max(size.width / size.height, 1), 16.0 / 9.0)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: skin.cornerRadius)
            .fill(skin.surface)
            .overlay {
                if showsVideo {
                    VideoPaneView()
                } else if let artwork {
                    // The downloaded thumbnail, with the visualizer along the bottom if it's on.
                    GeometryReader { geo in
                        ZStack(alignment: .bottom) {
                            Image(nsImage: artwork)
                                .resizable()
                                .scaledToFill()
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
                            if let style = VisualizerStyle(rawValue: styleRaw) {
                                VisualizerView(style: style)
                                    .frame(height: geo.size.height * 0.35)
                                    .padding(10)
                                    .background(
                                        LinearGradient(colors: [.clear, .black.opacity(0.55)],
                                                       startPoint: .top, endPoint: .bottom)
                                    )
                            }
                        }
                    }
                } else if let style = VisualizerStyle(rawValue: styleRaw) {
                    VisualizerView(style: style).padding(16)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 64))
                        .foregroundStyle(skin.accent.opacity(0.8))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: skin.cornerRadius))
            .overlay(alignment: .bottomTrailing) {
                if !showsVideo {
                    Image(systemName: "waveform")
                        .font(.caption)
                        .foregroundStyle(skin.secondaryText.opacity(0.7))
                        .padding(8)
                }
            }
            // Video gets a widescreen frame; audio keeps the square.
            .aspectRatio(frameRatio, contentMode: .fit)
            .contentShape(Rectangle())
            .onTapGesture { if !showsVideo { styleRaw = VisualizerStyle.cycle(after: styleRaw) } }
            .help(showsVideo ? "" : "Click to change the visualization")
    }
}

struct SeekBar: View {
    @EnvironmentObject private var engine: PlayerEngine
    @Environment(\.skin) private var skin
    @State private var isDragging = false
    @State private var dragValue: Double = 0

    var body: some View {
        HStack(spacing: 8) {
            Text(formatTime(isDragging ? dragValue : engine.currentTime))
                .font(skin.bodyFont.monospacedDigit())
                .foregroundStyle(skin.secondaryText)
                .frame(width: 42, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { isDragging ? dragValue : engine.currentTime },
                    set: { dragValue = $0 }
                ),
                in: 0...max(engine.duration, 0.01),
                onEditingChanged: { editing in
                    if editing {
                        dragValue = engine.currentTime
                    } else {
                        engine.seek(to: dragValue)
                    }
                    isDragging = editing
                }
            )
            .tint(skin.accent)
            .disabled(engine.currentTrack == nil)

            Text(formatTime(engine.duration))
                .font(skin.bodyFont.monospacedDigit())
                .foregroundStyle(skin.secondaryText)
                .frame(width: 42, alignment: .leading)
        }
    }
}

struct TransportControls: View {
    @EnvironmentObject private var engine: PlayerEngine
    @Environment(\.skin) private var skin

    var body: some View {
        HStack(spacing: skin.spacing * 1.4) {
            toggle("shuffle", isOn: engine.shuffle) { engine.shuffle.toggle() }

            button("backward.fill") { engine.previous() }

            button(engine.isPlaying ? "pause.circle.fill" : "play.circle.fill",
                   scale: 1.9) { engine.togglePlayPause() }
                .keyboardShortcut(.space, modifiers: [])

            button("forward.fill") { engine.next() }

            toggle(engine.repeatMode.symbol, isOn: engine.repeatMode != .off) {
                engine.repeatMode = engine.repeatMode.next
            }
        }
    }

    private func button(_ symbol: String, scale: CGFloat = 1,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: skin.controlSize * scale))
                .foregroundStyle(skin.text)
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ symbol: String, isOn: Bool,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: skin.controlSize * 0.65))
                .foregroundStyle(isOn ? skin.accent : skin.secondaryText)
        }
        .buttonStyle(.plain)
    }
}

struct VolumeSlider: View {
    @EnvironmentObject private var engine: PlayerEngine
    @Environment(\.skin) private var skin

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill")
                .foregroundStyle(skin.secondaryText)
            Slider(value: Binding(
                get: { Double(engine.volume) },
                set: { engine.volume = Float($0) }
            ), in: 0...1)
            .tint(skin.accent)
            Image(systemName: "speaker.wave.3.fill")
                .foregroundStyle(skin.secondaryText)
        }
    }
}

struct PlaylistView: View {
    @EnvironmentObject private var engine: PlayerEngine
    @Environment(\.skin) private var skin

    var body: some View {
        Group {
            if engine.queue.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 28))
                    Text("Drop audio files here, press ⌘O, or use Get to download songs")
                        .font(skin.bodyFont)
                }
                .foregroundStyle(skin.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(engine.queue.enumerated()), id: \.element.id) { index, track in
                        HStack {
                            Image(systemName: index == engine.currentIndex
                                  ? "speaker.wave.2.fill" : "music.note")
                                .foregroundStyle(index == engine.currentIndex
                                                 ? skin.accent : skin.secondaryText)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(track.title)
                                    .font(skin.bodyFont)
                                    .foregroundStyle(skin.text)
                                    .lineLimit(1)
                                if !track.artist.isEmpty {
                                    Text(track.artist)
                                        .font(skin.bodyFont.weight(.light))
                                        .foregroundStyle(skin.secondaryText)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { engine.play(index: index) }
                        .listRowBackground(
                            index == engine.currentIndex
                                ? skin.accent.opacity(0.15) : Color.clear
                        )
                    }
                    .onDelete { engine.remove(at: $0) }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(skin.surface.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: skin.cornerRadius))
    }
}
