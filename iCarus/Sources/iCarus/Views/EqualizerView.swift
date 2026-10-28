import SwiftUI

/// Built-in EQ panel (opened with ⌘E in Play). Skins can also place EQ
/// widgets directly using the bass / treble / eqBand / balance bindings.
struct EqualizerView: View {
    @EnvironmentObject private var engine: PlayerEngine
    @Environment(\.skin) private var skin
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 12) {
                Text("Equalizer")
                    .font(skin.titleFont)
                Spacer()
                Toggle("On", isOn: $engine.eqEnabled)
                    .toggleStyle(.switch)
                Menu("Presets") {
                    ForEach(EQPreset.all) { preset in
                        Button(preset.name) { engine.applyPreset(preset) }
                    }
                }
                .fixedSize()
                Button("Reset") { engine.resetEQ() }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            HStack(alignment: .bottom, spacing: 12) {
                ForEach(0..<EQ.bandCount, id: \.self) { band in
                    VStack(spacing: 6) {
                        Text(String(format: "%+.0f", Double(engine.eqGains[band])))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(skin.secondaryText)
                        // A vertical slider is a horizontal one rotated.
                        Slider(
                            value: Binding(
                                get: { Double(engine.eqGains[band]) },
                                set: { value in
                                    // Snap to 0 dB near the middle.
                                    engine.setEQGain(abs(value) < 0.4 ? 0 : Float(value), band: band)
                                }
                            ),
                            in: Double(-EQ.range)...Double(EQ.range)
                        )
                        .frame(width: 150)
                        .rotationEffect(.degrees(-90))
                        .frame(width: 28, height: 150)
                        Text(EQ.label(band))
                            .font(.caption2)
                            .foregroundStyle(skin.secondaryText)
                    }
                }
            }
            .opacity(engine.eqEnabled ? 1 : 0.4)

            HStack(spacing: 10) {
                Text("L").foregroundStyle(skin.secondaryText)
                Slider(
                    value: Binding(
                        get: { Double(engine.balance) },
                        set: { engine.balance = abs($0) < 0.04 ? 0 : Float($0) }
                    ),
                    in: -1...1
                )
                Text("R").foregroundStyle(skin.secondaryText)
                Text("Balance")
                    .font(skin.bodyFont)
                    .foregroundStyle(skin.secondaryText)
                    .frame(width: 60, alignment: .leading)
            }
        }
        .padding(22)
        .frame(width: 560)
        .background(skin.background)
        .foregroundStyle(skin.text)
        .tint(skin.accent)
        .preferredColorScheme(.dark)
    }
}
