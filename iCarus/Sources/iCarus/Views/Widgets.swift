import SwiftUI

// MARK: - Widget system
//
// A skin can describe its interface as a list of widgets placed on a fixed
// canvas. Each widget has a KIND (how it looks/behaves: knob, button, ...)
// and a BINDING (which player function it is wired to). Bindings come from a
// fixed whitelist below, so a skin can never run code, only choose wiring.
//
// Coordinates: x/y are the CENTER of the widget, in canvas units. The whole
// canvas is scaled uniformly to fit the window.

enum WidgetKind: String, Codable {
    case knob      // rotary control, drag up/right to increase
    case button    // push button (SF Symbol)
    case slider    // tuner scale with a moving needle
    case display   // backlit text readout
    case lamp      // indicator light
}

enum WidgetBinding: String, Codable {
    // values (knob, slider)
    case volume, seek
    // actions (button)
    case playPause, next, previous, shuffle, repeatMode
    // text (display)
    case trackTitle, trackArtist, elapsedTime
    // state (lamp)
    case isPlaying

    /// Seek is applied on release (seeking continuously while dragging is janky).
    var appliesLive: Bool { self != .seek }
}

struct WidgetSpec: Codable, Equatable, Identifiable {
    var id: String
    var kind: WidgetKind
    var binding: WidgetBinding
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    /// Button: SF Symbol name, and an optional one shown while the binding is "on".
    var symbol: String?
    var altSymbol: String?
    /// Display: text size.
    var fontSize: Double?
    /// Knob: sweep range in degrees, 0 = straight up.
    var minAngle: Double?
    var maxAngle: Double?
}

struct WidgetLayout: Codable, Equatable {
    var canvasWidth: Double
    var canvasHeight: Double
    var widgets: [WidgetSpec]
}

// MARK: - Bridge to the player
//
// This is the ONLY place widgets touch the engine, so the set of things a
// skin can do is defined right here.

extension PlayerEngine {
    func value(for binding: WidgetBinding) -> Double {
        switch binding {
        case .volume: return Double(volume)
        case .seek: return duration > 0 ? min(max(currentTime / duration, 0), 1) : 0
        default: return 0
        }
    }

    func setValue(_ value: Double, for binding: WidgetBinding) {
        let v = min(max(value, 0), 1)
        switch binding {
        case .volume: volume = Float(v)
        case .seek: if duration > 0 { seek(to: v * duration) }
        default: break
        }
    }

    func trigger(_ binding: WidgetBinding) {
        switch binding {
        case .playPause: togglePlayPause()
        case .next: next()
        case .previous: previous()
        case .shuffle: shuffle.toggle()
        case .repeatMode: repeatMode = repeatMode.next
        default: break
        }
    }

    func isOn(_ binding: WidgetBinding) -> Bool {
        switch binding {
        case .playPause, .isPlaying: return isPlaying
        case .shuffle: return shuffle
        case .repeatMode: return repeatMode != .off
        default: return false
        }
    }

    func text(for binding: WidgetBinding) -> String {
        switch binding {
        case .trackTitle: return currentTrack?.title ?? "No signal"
        case .trackArtist: return currentTrack?.artist ?? ""
        case .elapsedTime: return "\(formatTime(currentTime)) / \(formatTime(duration))"
        default: return ""
        }
    }
}

// MARK: - Canvas (places widgets and scales them to the window)

struct WidgetCanvas: View {
    let layout: WidgetLayout
    @Environment(\.skin) private var skin

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / layout.canvasWidth,
                            geo.size.height / layout.canvasHeight)
            ZStack(alignment: .topLeading) {
                faceplate
                ForEach(layout.widgets) { spec in
                    WidgetView(spec: spec)
                        .position(x: spec.x, y: spec.y)
                }
            }
            .frame(width: layout.canvasWidth, height: layout.canvasHeight, alignment: .topLeading)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: layout.canvasWidth * scale,
                   height: layout.canvasHeight * scale,
                   alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var faceplate: some View {
        RoundedRectangle(cornerRadius: skin.cornerRadius * 1.5)
            .fill(LinearGradient(colors: [skin.surface, skin.background],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(
                RoundedRectangle(cornerRadius: skin.cornerRadius * 1.5)
                    .stroke(skin.secondaryText.opacity(0.35), lineWidth: 2)
            )
    }
}

struct WidgetView: View {
    let spec: WidgetSpec

    var body: some View {
        Group {
            switch spec.kind {
            case .knob: KnobWidget(spec: spec)
            case .button: ButtonWidget(spec: spec)
            case .slider: TunerWidget(spec: spec)
            case .display: DisplayWidget(spec: spec)
            case .lamp: LampWidget(spec: spec)
            }
        }
        .frame(width: spec.width, height: spec.height)
    }
}

// MARK: - Knob

struct KnobWidget: View {
    let spec: WidgetSpec
    @EnvironmentObject private var engine: PlayerEngine
    @Environment(\.skin) private var skin
    @State private var dragValue: Double?
    @State private var startValue = 0.0

    private var value: Double { dragValue ?? engine.value(for: spec.binding) }

    var body: some View {
        let minAngle = spec.minAngle ?? -135
        let maxAngle = spec.maxAngle ?? 135
        let angle = minAngle + (maxAngle - minAngle) * value
        let size = min(spec.width, spec.height)
        let bodySize = size * 0.76

        ZStack {
            // Tick marks around the knob
            Canvas { context, canvasSize in
                let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                let radius = min(canvasSize.width, canvasSize.height) / 2
                for i in 0...10 {
                    let degrees = minAngle + (maxAngle - minAngle) * Double(i) / 10 - 90
                    let a = degrees * .pi / 180
                    var path = Path()
                    path.move(to: CGPoint(x: center.x + cos(a) * radius * 0.88,
                                          y: center.y + sin(a) * radius * 0.88))
                    path.addLine(to: CGPoint(x: center.x + cos(a) * radius * 0.98,
                                             y: center.y + sin(a) * radius * 0.98))
                    context.stroke(path, with: .color(skin.secondaryText), lineWidth: 2)
                }
            }

            // Knob body
            Circle()
                .fill(RadialGradient(colors: [skin.surface.opacity(0.9), skin.background],
                                     center: .topLeading, startRadius: 2, endRadius: bodySize))
                .overlay(Circle().stroke(skin.secondaryText.opacity(0.6), lineWidth: 2))
                .shadow(color: .black.opacity(0.5), radius: 4, y: 3)
                .frame(width: bodySize, height: bodySize)

            // Pointer
            Capsule()
                .fill(skin.accent)
                .frame(width: bodySize * 0.07, height: bodySize * 0.3)
                .padding(.top, bodySize * 0.08)
                .frame(width: bodySize, height: bodySize, alignment: .top)
                .rotationEffect(.degrees(angle))
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if dragValue == nil { startValue = engine.value(for: spec.binding) }
                    // Drag up or right to turn clockwise.
                    let delta = (drag.translation.width - drag.translation.height) / 180
                    let newValue = min(max(startValue + delta, 0), 1)
                    dragValue = newValue
                    if spec.binding.appliesLive { engine.setValue(newValue, for: spec.binding) }
                }
                .onEnded { _ in
                    if let dragValue, !spec.binding.appliesLive {
                        engine.setValue(dragValue, for: spec.binding)
                    }
                    dragValue = nil
                }
        )
    }
}

// MARK: - Button

struct ButtonWidget: View {
    let spec: WidgetSpec
    @EnvironmentObject private var engine: PlayerEngine
    @Environment(\.skin) private var skin

    private var isToggle: Bool { spec.binding == .shuffle || spec.binding == .repeatMode }

    var body: some View {
        let on = engine.isOn(spec.binding)
        let symbol = (on ? spec.altSymbol : nil) ?? spec.symbol ?? "circle"

        Button {
            engine.trigger(spec.binding)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: min(spec.width, spec.height) * 0.45, weight: .semibold))
                .foregroundStyle(isToggle && on ? skin.accent : skin.text)
                .frame(width: spec.width, height: spec.height)
                .background(
                    RoundedRectangle(cornerRadius: skin.cornerRadius * 0.5)
                        .fill(LinearGradient(colors: [skin.surface, skin.background],
                                             startPoint: .top, endPoint: .bottom))
                        .overlay(
                            RoundedRectangle(cornerRadius: skin.cornerRadius * 0.5)
                                .stroke(skin.secondaryText.opacity(0.5), lineWidth: 1.5)
                        )
                        .shadow(color: .black.opacity(0.4), radius: 2, y: 2)
                )
        }
        .buttonStyle(PressableButtonStyle())
    }
}

private struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .brightness(configuration.isPressed ? -0.15 : 0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

// MARK: - Tuner (slider with a needle over a tick scale)

struct TunerWidget: View {
    let spec: WidgetSpec
    @EnvironmentObject private var engine: PlayerEngine
    @Environment(\.skin) private var skin
    @State private var dragValue: Double?

    private var value: Double { dragValue ?? engine.value(for: spec.binding) }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.45))

                Canvas { context, size in
                    let count = 40
                    for i in 0...count {
                        let x = size.width * Double(i) / Double(count)
                        let tall = i % 5 == 0
                        var path = Path()
                        path.move(to: CGPoint(x: x, y: size.height))
                        path.addLine(to: CGPoint(x: x, y: size.height * (tall ? 0.5 : 0.7)))
                        context.stroke(path, with: .color(skin.secondaryText.opacity(0.8)),
                                       lineWidth: tall ? 1.5 : 1)
                    }
                }

                Capsule()
                    .fill(skin.accent)
                    .frame(width: 3, height: height)
                    .shadow(color: skin.accent.opacity(0.9), radius: 4)
                    .offset(x: value * width - 1.5)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let newValue = min(max(drag.location.x / width, 0), 1)
                        dragValue = newValue
                        if spec.binding.appliesLive { engine.setValue(newValue, for: spec.binding) }
                    }
                    .onEnded { _ in
                        if let dragValue, !spec.binding.appliesLive {
                            engine.setValue(dragValue, for: spec.binding)
                        }
                        dragValue = nil
                    }
            )
        }
    }
}

// MARK: - Display

struct DisplayWidget: View {
    let spec: WidgetSpec
    @EnvironmentObject private var engine: PlayerEngine
    @Environment(\.skin) private var skin

    var body: some View {
        Text(engine.text(for: spec.binding))
            .textCase(.uppercase)
            .font(.system(size: spec.fontSize ?? 16, weight: .medium, design: .monospaced))
            .foregroundStyle(skin.accent)
            .shadow(color: skin.accent.opacity(0.8), radius: 4)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 10)
            .frame(width: spec.width, height: spec.height)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.55))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(skin.secondaryText.opacity(0.4), lineWidth: 1))
            )
    }
}

// MARK: - Lamp

struct LampWidget: View {
    let spec: WidgetSpec
    @EnvironmentObject private var engine: PlayerEngine
    @Environment(\.skin) private var skin

    var body: some View {
        let on = engine.isOn(spec.binding)
        Circle()
            .fill(skin.accent.opacity(on ? 1 : 0.15))
            .overlay(Circle().stroke(skin.secondaryText.opacity(0.6), lineWidth: 1))
            .shadow(color: skin.accent.opacity(on ? 0.9 : 0), radius: 6)
            .animation(.easeInOut(duration: 0.2), value: on)
            .frame(width: spec.width, height: spec.height)
    }
}

// MARK: - Demo skin: a retro radio, built from widgets

extension WidgetLayout {
    static let retroRadio = WidgetLayout(
        canvasWidth: 720,
        canvasHeight: 260,
        widgets: [
            WidgetSpec(id: "title", kind: .display, binding: .trackTitle,
                       x: 360, y: 52, width: 380, height: 48, fontSize: 18),
            WidgetSpec(id: "tuner", kind: .slider, binding: .seek,
                       x: 360, y: 124, width: 380, height: 48),
            WidgetSpec(id: "time", kind: .display, binding: .elapsedTime,
                       x: 360, y: 170, width: 150, height: 26, fontSize: 12),
            WidgetSpec(id: "volume", kind: .knob, binding: .volume,
                       x: 95, y: 125, width: 120, height: 120),
            WidgetSpec(id: "tuning", kind: .knob, binding: .seek,
                       x: 625, y: 125, width: 120, height: 120),
            WidgetSpec(id: "shuffle", kind: .button, binding: .shuffle,
                       x: 180, y: 225, width: 48, height: 36, symbol: "shuffle"),
            WidgetSpec(id: "prev", kind: .button, binding: .previous,
                       x: 285, y: 225, width: 70, height: 40, symbol: "backward.fill"),
            WidgetSpec(id: "play", kind: .button, binding: .playPause,
                       x: 360, y: 225, width: 70, height: 40, symbol: "play.fill",
                       altSymbol: "pause.fill"),
            WidgetSpec(id: "next", kind: .button, binding: .next,
                       x: 435, y: 225, width: 70, height: 40, symbol: "forward.fill"),
            WidgetSpec(id: "repeat", kind: .button, binding: .repeatMode,
                       x: 540, y: 225, width: 48, height: 36, symbol: "repeat"),
            WidgetSpec(id: "lamp", kind: .lamp, binding: .isPlaying,
                       x: 640, y: 36, width: 14, height: 14)
        ]
    )
}

extension Skin {
    static let retroRadio = Skin(
        manifest: SkinManifest(
            id: "builtin.retroradio",
            name: "Retro Radio (preview)",
            author: "iCarus",
            version: "0.1",
            layout: .widgets,
            colors: .init(
                background: "#1A120B",
                surface: "#4A3322",
                accent: "#FFB347",
                text: "#F3E3C3",
                secondaryText: "#A58A66"
            ),
            typography: .init(design: "monospaced", titleSize: 16, bodySize: 12),
            metrics: .init(cornerRadius: 14, spacing: 12, controlSize: 26,
                           windowWidth: 720, windowHeight: 260),
            backgroundImage: nil,
            widgets: .retroRadio
        ),
        directory: nil
    )
}
