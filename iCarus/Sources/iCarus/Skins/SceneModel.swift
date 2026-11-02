import Foundation

// A skin imported from Windows Media Player keeps the layout's real structure: a tree of
// elements, each with its own position, stacking order and visibility. Those properties can
// change while the skin runs (SceneRuntime), which is what scripts will drive.
//
// Coordinates: a node's left/top are relative to its parent. Its drawing (`specs`) is placed
// relative to the node's own top-left corner.

struct SceneNode: Codable, Equatable, Identifiable {
    /// The layout's id (lower-cased; names are case-insensitive), or a generated one.
    var id: String
    /// The layout tag: "subview", "button", "text", "player", ...
    var tag: String
    /// The id as the layout spelled it (scripts may use that exact spelling).
    var name: String?
    /// A few attributes scripts read: value, tooltip, uptooltip, min, max.
    var props: [String: String] = [:]
    var left: Double = 0
    var top: Double = 0
    var width: Double?
    var height: Double?
    /// When left/top are worked out by script in the layout (e.g. "bass.top+21"), the
    /// expression is kept so the position follows the element it refers to.
    var leftExpr: String?
    var topExpr: String?
    var zIndex = 0
    var visible = true
    var enabled = true
    /// What this node draws itself (relative to its own corner). Empty for pure containers.
    var specs: [WidgetSpec] = []
    /// Event handlers from the layout, e.g. "onclick": "OpenScreen(audPane);". Not run yet.
    var events: [String: String] = [:]
    /// Children in document order.
    var children: [SceneNode] = []
}

struct SceneLayout: Codable, Equatable, Identifiable {
    /// "main" for the first view, otherwise the view's id (e.g. "playview").
    var id: String
    var canvasWidth: Double
    var canvasHeight: Double
    var root: SceneNode

    /// Every node, parents before children.
    var allNodes: [SceneNode] {
        var result: [SceneNode] = []
        func walk(_ node: SceneNode) {
            result.append(node)
            node.children.forEach(walk)
        }
        walk(root)
        return result
    }
}
