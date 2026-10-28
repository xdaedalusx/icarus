import SwiftUI
import AppKit

// Widgets drawn from a skin's own artwork instead of the built-in look.
//
// Sprite strips: like Windows Media Player skins, several buttons can share one
// image file. Each widget picks its piece with `crop` = [x, y, width, height]
// in image pixels, and the SAME crop is applied to its up/hover/down/disabled
// images (so those files simply line up cell for cell).

// MARK: - Static artwork (faceplate, decoration)

struct ImageLayerWidget: View {
    let spec: WidgetSpec
    @Environment(\.skin) private var skin

    var body: some View {
        Group {
            if let image = skin.image(named: spec.image, crop: spec.crop) {
                Image(decorative: image, scale: 1).resizable()
            } else {
                Color.clear
            }
        }
        .frame(width: spec.width, height: spec.height)
        .allowsHitTesting(false)   // never steals clicks from controls or window dragging
    }
}

// MARK: - Image button

struct ImageButtonWidget: View {
    let spec: WidgetSpec
    @EnvironmentObject private var engine: PlayerEngine
    @Environment(\.skin) private var skin
    @State private var hovering = false

    private var isToggle: Bool {
        [.shuffle, .repeatMode, .eqEnabled].contains(spec.binding)
    }

    var body: some View {
        let enabled = engine.isEnabled(spec.binding)
        let on = isToggle && engine.isOn(spec.binding)

        Button {
            performWidgetAction(spec.binding, engine: engine)
        } label: {
            Color.clear   // the style below draws the artwork
        }
        .buttonStyle(ImageButtonStyle(spec: spec, skin: skin,
                                      hovering: hovering, enabled: enabled, on: on))
        .disabled(!enabled)
        .onHover { hovering = $0 }
    }
}

private struct ImageButtonStyle: ButtonStyle {
    let spec: WidgetSpec
    let skin: Skin
    let hovering: Bool
    let enabled: Bool
    let on: Bool

    func makeBody(configuration: Configuration) -> some View {
        let name: String?
        if !enabled {
            name = spec.disabledImage ?? spec.image
        } else if configuration.isPressed || on {
            name = spec.downImage ?? spec.image
        } else if hovering {
            name = spec.hoverImage ?? spec.image
        } else {
            name = spec.image
        }

        return Group {
            if let image = skin.image(named: name, crop: spec.crop) {
                Image(decorative: image, scale: 1).resizable()
            } else {
                Color.clear
            }
        }
        .frame(width: spec.width, height: spec.height)
        .contentShape(Rectangle())
    }
}

// MARK: - Image slider (seek bar, volume, bass/treble, ...)
//
// image       the track (drawn at the widget's size)
// fillImage   optional; revealed from the start up to the current value
// thumbImage  the handle, drawn at its natural pixel size
// inset       how far in from each end the handle's CENTRE can travel
//             (WMP skins call this borderSize)
// vertical    true = bottom-to-top

struct ImageSliderWidget: View {
    let spec: WidgetSpec
    @EnvironmentObject private var engine: PlayerEngine
    @Environment(\.skin) private var skin
    @State private var dragValue: Double?

    private var value: Double { dragValue ?? engine.value(for: spec.binding) }

    var body: some View {
        let vertical = spec.vertical ?? false
        let width = spec.width
        let height = spec.height
        let inset = spec.inset ?? 0
        let travel = max((vertical ? height : width) - inset * 2, 1)
        let offset = inset + value * travel
        let thumbName = (dragValue != nil ? spec.thumbDownImage : nil) ?? spec.thumbImage

        ZStack(alignment: .topLeading) {
            if let track = skin.image(named: spec.image) {
                Image(decorative: track, scale: 1).resizable()
                    .frame(width: width, height: height)
            }

            if let fill = skin.image(named: spec.fillImage) {
                Image(decorative: fill, scale: 1).resizable()
                    .frame(width: width, height: height)
                    .mask(alignment: vertical ? .bottomLeading : .topLeading) {
                        Rectangle().frame(width: vertical ? width : offset,
                                          height: vertical ? offset : height)
                    }
            }

            if let thumb = skin.image(named: thumbName) {
                Image(decorative: thumb, scale: 1)
                    .position(x: vertical ? width / 2 : offset,
                              y: vertical ? height - offset : height / 2)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let position = vertical ? (height - drag.location.y) : drag.location.x
                    let newValue = min(max((position - inset) / travel, 0), 1)
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
