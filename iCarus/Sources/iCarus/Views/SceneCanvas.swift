import SwiftUI

/// Draws an imported skin from its element tree, using the live state in SceneRuntime
/// (so showing, hiding, moving or re-stacking an element changes the picture).
struct SceneCanvas: View {
    let layouts: [SceneLayout]
    @EnvironmentObject private var runtime: SceneRuntime
    @EnvironmentObject private var engine: PlayerEngine
    @EnvironmentObject private var appState: AppState
    @Environment(\.skin) private var skin

    var body: some View {
        Group {
            if let scene = runtime.currentScene ?? layouts.first {
                GeometryReader { geo in
                    let scale = min(geo.size.width / scene.canvasWidth,
                                    geo.size.height / scene.canvasHeight)
                    let size = CGSize(width: scene.canvasWidth, height: scene.canvasHeight)
                    ZStack(alignment: .topLeading) {
                        // Pictures ignore clicks so they never block a control; this layer lets
                        // you drag the window by the artwork.
                        WindowDragSurface().frame(width: size.width, height: size.height)
                        SceneNodeView(node: scene.root, size: size)
                    }
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: size.width * scale, height: size.height * scale, alignment: .topLeading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear {
            runtime.load(layouts)
            runtime.startScripts(skin: skin, engine: engine, appState: appState)
        }
        .onChange(of: layouts) { newLayouts in
            runtime.load(newLayouts)
            runtime.startScripts(skin: skin, engine: engine, appState: appState)
        }
    }
}

/// One element: first the children that sit beneath its picture, then its own drawing, then the
/// children above it. Hidden elements (and everything inside them) aren't drawn at all.
struct SceneNodeView: View {
    let node: SceneNode
    let size: CGSize
    @EnvironmentObject private var runtime: SceneRuntime

    var body: some View {
        if runtime.isVisible(node) {
            let layers = runtime.layers(of: node)
            ZStack(alignment: .topLeading) {
                ForEach(layers.below) { SceneNodeView(node: $0, size: size) }
                ForEach(node.specs) { spec in
                    WidgetView(spec: spec).position(x: spec.x, y: spec.y)
                }
                ForEach(layers.above) { SceneNodeView(node: $0, size: size) }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .offset(x: runtime.left(node), y: runtime.top(node))
        }
    }
}
