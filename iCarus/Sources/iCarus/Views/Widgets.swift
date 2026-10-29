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
    case visualization  // live audio: bars / waveform / radial (binding is ignored)
    case videoPane      // picture for files that have video (binding is ignored)
    // Drawn from the skin's own artwork (see ImageWidgets.swift); binding is ignored for .image
    case image          // static artwork: faceplate, decoration
    case imageButton    // button with up / hover / down / disabled images
    case imageSlider    // track + optional fill + thumb images
    case filmstripSlider // one picture per position side by side, plus a grey "position map"
}

enum WidgetBinding: String, Codable {
    // values (knob, slider)
    case volume, seek
    // actions (button)
    case playPause, next, previous, shuffle, repeatMode
    // text (display)
    case trackTitle, trackArtist, elapsedTime, positionTime, durationTime
    // state (lamp)
    case isPlaying
    // equalizer: bass = band 1, treble = band 10 (knob / slider)
    case bass, treble, balance
    case eqBand1, eqBand2, eqBand3, eqBand4, eqBand5
    case eqBand6, eqBand7, eqBand8, eqBand9, eqBand10
    // equalizer actions / state (button, lamp)
    case eqEnabled, eqReset
    // transport + window actions (button)
    case play, pause, stop, closeWindow, minimizeWindow
    // panels and visualizer (button)
    case showEqualizer, showPlaylist, nextVisualization, previousVisualization
    case openFiles, skipBack, skipForward

    /// Which EQ band this binding controls, if any.
    var eqBandIndex: Int? {
        switch self {
        case .bass, .eqBand1: return 0
        case .eqBand2: return 1
        case .eqBand3: return 2
        case .eqBand4: return 3
        case .eqBand5: return 4
        case .eqBand6: return 5
        case .eqBand7: return 6
        case .eqBand8: return 7
        case .eqBand9: return 8
        case .treble, .eqBand10: return 9
        default: return nil
        }
    }

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
    /// Visualization: "bars", "waveform" or "radial".
    var style: String?
    // Image widgets. Files live in the skin folder; `crop` = [x, y, w, h] in image pixels.
    var image: String?
    var hoverImage: String?
    var downImage: String?
    var disabledImage: String?
    var thumbImage: String?
    var thumbDownImage: String?
    var fillImage: String?
    var crop: [Double]?
    var vertical: Bool?
    /// Image slider: how far in from each end the thumb's centre can travel.
    var inset: Double?
    /// Plain display text: colour ("#RRGGBB") and alignment ("leading", "center", "trailing").
    var textColor: String?
    var align: String?
    /// Visualization: draw with no panel behind it (the skin's artwork frames it).
    var bare: Bool?
    /// Filmstrip slider: the grey position map's file, and how many pictures the strip holds.
    var positionImage: String?
    var frames: Int?
}

struct WidgetLayout: Codable, Equatable {
    var canvasWidth: Double
    var canvasHeight: Double
    var widgets: [WidgetSpec]
    /// false = don't draw the built-in faceplate (the skin supplies its own artwork).
    var showsFaceplate: Bool?
    /// true = borderless transparent window whose outline follows the artwork's transparency.
    var shaped: Bool?
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
        case .balance: return Double(balance + 1) / 2
        default:
            // EQ bands map -range...+range dB onto 0...1 (0.5 = flat).
            if let band = binding.eqBandIndex { return Double(eqGains[band] / EQ.range + 1) / 2 }
            return 0
        }
    }

    func setValue(_ value: Double, for binding: WidgetBinding) {
        let v = min(max(value, 0), 1)
        switch binding {
        case .volume: volume = Float(v)
        case .seek: if duration > 0 { seek(to: v * duration) }
        case .balance: balance = snapToCenter(Float(v * 2 - 1))
        default:
            if let band = binding.eqBandIndex {
                setEQGain(snapToCenter(Float(v * 2 - 1)) * EQ.range, band: band)
            }
        }
    }

    func trigger(_ binding: WidgetBinding) {
        switch binding {
        case .playPause: togglePlayPause()
        case .next: next()
        case .previous: previous()
        case .shuffle: shuffle.toggle()
        case .repeatMode: repeatMode = repeatMode.next
        case .eqEnabled: eqEnabled.toggle()
        case .eqReset: resetEQ()
        case .play: if !isPlaying { togglePlayPause() }
        case .pause: if isPlaying { togglePlayPause() }
        case .stop: stop()
        case .nextVisualization: visualizerChoice = VisualizerStyle.cycle(after: visualizerChoice)
        case .previousVisualization: visualizerChoice = VisualizerStyle.cycleBack(after: visualizerChoice)
        case .skipBack: seek(to: max(0, currentTime - 10))
        case .skipForward: seek(to: min(max(duration - 0.5, 0), currentTime + 10))
        default: break
        }
    }

    /// Whether a control should look usable right now (drives the disabled image).
    func isEnabled(_ binding: WidgetBinding) -> Bool {
        switch binding {
        case .playPause, .play, .next, .previous: return !queue.isEmpty
        case .skipBack, .skipForward: return currentTrack != nil
        case .pause: return isPlaying
        case .stop: return currentTrack != nil
        default: return true
        }
    }

    func isOn(_ binding: WidgetBinding) -> Bool {
        switch binding {
        case .playPause, .isPlaying: return isPlaying
        case .shuffle: return shuffle
        case .repeatMode: return repeatMode != .off
        case .eqEnabled: return eqEnabled
        default: return false
        }
    }

    func text(for binding: WidgetBinding) -> String {
        switch binding {
        case .trackTitle: return currentTrack?.title ?? "No signal"
        case .trackArtist: return currentTrack?.artist ?? ""
        case .elapsedTime: return "\(formatTime(currentTime)) / \(formatTime(duration))"
        case .positionTime: return formatTime(currentTime)
        case .durationTime: return formatTime(duration)
        default: return ""
        }
    }
}

/// Runs a button's action: window actions here, everything else through the engine.
@MainActor
func performWidgetAction(_ binding: WidgetBinding, engine: PlayerEngine, appState: AppState? = nil) {
    switch binding {
    case .showEqualizer: appState?.showingEQ = true
    case .showPlaylist: appState?.showingPlaylist = true
    case .openFiles: appState?.showingImporter = true
    case .closeWindow: NSApp.keyWindow?.performClose(nil)
    case .minimizeWindow: NSApp.keyWindow?.miniaturize(nil)
    default: engine.trigger(binding)
    }
}

/// Makes the centre of a -1...1 control "sticky" so flat/centred is easy to hit.
private func snapToCenter(_ x: Float) -> Float { abs(x) < 0.04 ? 0 : x }

// MARK: - Canvas (places widgets and scales them to the window)

struct WidgetCanvas: View {
    let layout: WidgetLayout
    @Environment(\.skin) private var skin

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / layout.canvasWidth,
                            geo.size.height / layout.canvasHeight)
            ZStack(alignment: .topLeading) {
                // Pictures ignore clicks (so they never block a control), which would leave nothing
                // to grab. This invisible layer underneath lets you drag the window by the artwork.
                if layout.shaped == true {
                    WindowDragSurface()
                        .frame(width: layout.canvasWidth, height: layout.canvasHeight)
                }
                if layout.showsFaceplate != false { faceplate }
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
            case .visualization: VisualizerWidget(spec: spec)
            case .videoPane: VideoPaneWidget(spec: spec)
            case .image: ImageLayerWidget(spec: spec)
            case .imageButton: ImageButtonWidget(spec: spec)
            case .imageSlider: ImageSliderWidget(spec: spec)
            case .filmstripSlider: FilmstripSliderWidget(spec: spec)
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
            if let knobImage = skin.image(named: spec.image, crop: spec.crop) {
                Image(decorative: knobImage, scale: 1).resizable()
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(angle))
            } else {
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
    @EnvironmentObject private var appState: AppState
    @Environment(\.skin) private var skin

    private var isToggle: Bool {
        [.shuffle, .repeatMode, .eqEnabled].contains(spec.binding)
    }

    var body: some View {
        let on = engine.isOn(spec.binding)
        let symbol = (on ? spec.altSymbol : nil) ?? spec.symbol ?? "circle"

        Button {
            performWidgetAction(spec.binding, engine: engine, appState: appState)
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
        if spec.style == "plain" {
            plain
        } else {
            lcd
        }
    }

    /// Bare text on top of the skin's own artwork (used by imported skins).
    private var plain: some View {
        let alignment: Alignment = spec.align == "trailing" ? .trailing : (spec.align == "center" ? .center : .leading)
        return Text(engine.text(for: spec.binding))
            .font(.system(size: spec.fontSize ?? 10))
            .foregroundStyle(Color(hex: spec.textColor ?? "#FFFFFF"))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: spec.width, height: spec.height, alignment: alignment)
            .allowsHitTesting(false)
    }

    private var lcd: some View {
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
                       x: 360, y: 14, width: 150, height: 22, fontSize: 11),
            WidgetSpec(id: "viz", kind: .visualization, binding: .isPlaying,
                       x: 360, y: 176, width: 380, height: 34, style: "bars"),
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
