import SwiftUI

enum VisualizerStyle: String, Codable, CaseIterable, Identifiable {
    case bars, waveform, radial

    var id: String { rawValue }

    /// Click-to-cycle order: off -> bars -> waveform -> radial -> off.
    /// "Off" is stored as any string that isn't a style.
    static func cycleBack(after raw: String) -> String {
        switch VisualizerStyle(rawValue: raw) {
        case nil: return VisualizerStyle.radial.rawValue
        case .radial: return VisualizerStyle.waveform.rawValue
        case .waveform: return VisualizerStyle.bars.rawValue
        case .bars: return "off"
        }
    }

    static func cycle(after raw: String) -> String {
        switch VisualizerStyle(rawValue: raw) {
        case nil: return VisualizerStyle.bars.rawValue
        case .bars: return VisualizerStyle.waveform.rawValue
        case .waveform: return VisualizerStyle.radial.rawValue
        case .radial: return "off"
        }
    }
}

/// Draws live audio. It only asks the engine to analyse audio while it is on
/// screen, so a hidden visualizer costs nothing.
struct VisualizerView: View {
    let style: VisualizerStyle
    @EnvironmentObject private var engine: PlayerEngine
    @Environment(\.skin) private var skin

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                _ = timeline.date   // redraw on every tick
                let frame = engine.analyzer.snapshot()
                switch style {
                case .bars: drawBars(&context, size, frame)
                case .waveform: drawWaveform(&context, size, frame)
                case .radial: drawRadial(&context, size, frame)
                }
            }
        }
        .onAppear { engine.beginVisualization() }
        .onDisappear { engine.endVisualization() }
    }

    // MARK: Styles

    private func drawBars(_ context: inout GraphicsContext, _ size: CGSize, _ frame: AudioFrame) {
        let count = frame.bands.count
        let slot = size.width / CGFloat(count)
        let barWidth = max(slot * 0.7, 1)
        for (i, value) in frame.bands.enumerated() {
            let height = max(CGFloat(value) * size.height, 2)
            let rect = CGRect(x: CGFloat(i) * slot + (slot - barWidth) / 2,
                              y: size.height - height,
                              width: barWidth,
                              height: height)
            context.fill(Path(roundedRect: rect, cornerRadius: min(barWidth / 2, 3)),
                         with: .color(skin.accent.opacity(0.35 + 0.65 * Double(value))))
        }
    }

    private func drawWaveform(_ context: inout GraphicsContext, _ size: CGSize, _ frame: AudioFrame) {
        let count = frame.waveform.count
        let mid = size.height / 2
        var path = Path()
        for (i, sample) in frame.waveform.enumerated() {
            let x = size.width * CGFloat(i) / CGFloat(count - 1)
            // Music is quiet relative to full scale, so boost for visibility.
            let amplitude = min(max(CGFloat(sample) * 2.5, -1), 1)
            let point = CGPoint(x: x, y: mid - amplitude * mid * 0.9)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        var glow = context
        glow.addFilter(.shadow(color: skin.accent.opacity(0.8), radius: 4))
        glow.stroke(path, with: .color(skin.accent),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }

    private func drawRadial(_ context: inout GraphicsContext, _ size: CGSize, _ frame: AudioFrame) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let half = min(size.width, size.height) / 2
        let inner = half * 0.28
        let reach = half - inner
        let count = frame.bands.count
        let spokes = count * 2   // mirrored so it's symmetrical

        for i in 0..<spokes {
            let band = i < count ? i : (spokes - 1 - i)
            let value = CGFloat(max(frame.bands[band], 0.03))
            let angle = (Double(i) / Double(spokes)) * 2 * .pi - .pi / 2
            let dx = CGFloat(cos(angle)), dy = CGFloat(sin(angle))
            var path = Path()
            path.move(to: CGPoint(x: center.x + dx * inner, y: center.y + dy * inner))
            path.addLine(to: CGPoint(x: center.x + dx * (inner + value * reach),
                                     y: center.y + dy * (inner + value * reach)))
            context.stroke(path, with: .color(skin.accent.opacity(0.4 + 0.6 * Double(value))),
                           style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
        context.stroke(Path(ellipseIn: CGRect(x: center.x - inner, y: center.y - inner,
                                              width: inner * 2, height: inner * 2)),
                       with: .color(skin.secondaryText.opacity(0.6)), lineWidth: 1.5)
    }
}

/// Widget wrapper so a skin can place a visualizer on its canvas.
/// (A visualization widget ignores its binding; the style comes from `style`.)
struct VisualizerWidget: View {
    let spec: WidgetSpec
    @EnvironmentObject private var engine: PlayerEngine
    @Environment(\.skin) private var skin

    /// "auto" follows the visualizer button; anything else is a fixed style.
    private var style: VisualizerStyle? {
        if spec.style == "auto" { return VisualizerStyle(rawValue: engine.visualizerChoice) }   // nil = off
        return VisualizerStyle(rawValue: spec.style ?? "") ?? .bars
    }

    var body: some View {
        if spec.bare == true {
            Group {
                // A picture of the video replaces the visualizer while a video plays.
                if let style, engine.currentTrack?.hasVideo != true { VisualizerView(style: style) }
            }
            .frame(width: spec.width, height: spec.height)
            .allowsHitTesting(false)
        } else {
            panel
        }
    }

    private var panel: some View {
        VisualizerView(style: style ?? .bars)
            .padding(4)
            .frame(width: spec.width, height: spec.height)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.45))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(skin.secondaryText.opacity(0.4), lineWidth: 1))
            )
    }
}
