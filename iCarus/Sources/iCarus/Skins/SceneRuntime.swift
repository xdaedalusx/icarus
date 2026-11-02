import Foundation
import SwiftUI

/// The live state of the imported skin that's on screen: what's visible, where things are and in
/// what order they stack. The layout gives the starting values; anything (soon, the skin's script)
/// can change them with `set`, and the picture updates.
@MainActor
final class SceneRuntime: ObservableObject {
    struct State: Equatable {
        var visible: Bool?
        var zIndex: Int?
        var left: Double?
        var top: Double?
        var enabled: Bool?
    }

    @Published private(set) var states: [String: State] = [:]
    @Published private(set) var scenes: [SceneLayout] = []
    /// Which view is showing (the first one at start).
    @Published private(set) var currentViewID = "main"

    private var nodes: [String: SceneNode] = [:]

    // Script support
    /// Values scripts (or the user's slider drags) have set on elements: ["bass": ["value": "3"]].
    @Published private(set) var props: [String: [String: String]] = [:]
    /// What the script engine has reported (errors, notes), newest last.
    @Published private(set) var scriptLog: [String] = []
    @Published private(set) var scriptsRunning = false
    private var host: ScriptHost?
    private var lastStart: (skin: Skin, engine: PlayerEngine, appState: AppState)?

    var currentScene: SceneLayout? {
        scenes.first { $0.id == currentViewID } ?? scenes.first
    }

    /// Called when a skin appears or changes. Starts everything from the layout's own values.
    func load(_ layouts: [SceneLayout]) {
        guard layouts != scenes else { return }
        scenes = layouts
        props = [:]
        states = [:]
        currentViewID = layouts.first?.id ?? "main"
        nodes = [:]
        for scene in layouts {
            for node in scene.allNodes where nodes[node.id] == nil { nodes[node.id] = node }
        }
    }

    // MARK: Reading

    func node(named name: String) -> SceneNode? { nodes[name.lowercased()] }

    func isVisible(_ node: SceneNode) -> Bool { states[node.id]?.visible ?? node.visible }
    func isEnabled(_ node: SceneNode) -> Bool { states[node.id]?.enabled ?? node.enabled }

    /// Stacking level. A video window always stays above its parent's picture, like in WMP.
    func zIndex(_ node: SceneNode) -> Int {
        let value = states[node.id]?.zIndex ?? node.zIndex
        return node.tag == "video" ? max(value, 0) : value
    }

    func left(_ node: SceneNode) -> Double {
        if let value = states[node.id]?.left { return value }
        if let expression = node.leftExpr, let value = evaluate(expression, depth: 0) { return value }
        return node.left
    }

    func top(_ node: SceneNode) -> Double {
        if let value = states[node.id]?.top { return value }
        if let expression = node.topExpr, let value = evaluate(expression, depth: 0) { return value }
        return node.top
    }

    /// Children split into "beneath this element's own picture" (negative level) and "above it",
    /// each in stacking order. Equal levels keep document order, except that a video window goes
    /// before its siblings so a visualizer is drawn over the picture.
    func layers(of node: SceneNode) -> (below: [SceneNode], above: [SceneNode]) {
        let sorted = node.children.enumerated().sorted { a, b in
            let za = zIndex(a.element), zb = zIndex(b.element)
            if za != zb { return za < zb }
            let videoA = a.element.tag == "video", videoB = b.element.tag == "video"
            if videoA != videoB { return videoA }
            return a.offset < b.offset
        }.map { $0.element }
        return (sorted.filter { zIndex($0) < 0 }, sorted.filter { zIndex($0) >= 0 })
    }

    // MARK: Changing

    /// Changes properties of the element with this id (case-insensitive). Returns false if the
    /// skin has no such element.
    @discardableResult
    func set(_ name: String, visible: Bool? = nil, zIndex: Int? = nil,
             left: Double? = nil, top: Double? = nil, enabled: Bool? = nil) -> Bool {
        let key = name.lowercased()
        guard nodes[key] != nil else { return false }
        var state = states[key] ?? State()
        if let visible { state.visible = visible }
        if let zIndex { state.zIndex = zIndex }
        if let left { state.left = left }
        if let top { state.top = top }
        if let enabled { state.enabled = enabled }
        states[key] = state
        return true
    }

    func showView(_ id: String) {
        if scenes.contains(where: { $0.id == id.lowercased() }) { currentViewID = id.lowercased() }
    }

    /// Back to the layout's starting values.
    func reset() {
        props = [:]
        states = [:]
        currentViewID = scenes.first?.id ?? "main"
    }

    // MARK: Expressions

    /// Understands what layouts actually write: a number, or "other.left|top|width|height" with an
    /// optional "+ n" / "- n" ("bass.top+21"). Anything fancier returns nil (the stored value is used).
    private func evaluate(_ expression: String, depth: Int) -> Double? {
        guard depth < 8 else { return nil }   // guards against two elements pointing at each other
        let text = expression.replacingOccurrences(of: " ", with: "").lowercased()
        if let number = Double(text) { return number }

        var reference = text
        var offset = 0.0
        if let sign = text.firstIndex(where: { $0 == "+" || $0 == "-" }), sign != text.startIndex {
            reference = String(text[..<sign])
            guard let amount = Double(text[text.index(after: sign)...]) else { return nil }
            offset = text[sign] == "-" ? -amount : amount
        }
        let parts = reference.split(separator: ".")
        guard parts.count == 2, let target = nodes[String(parts[0])] else { return nil }

        switch parts[1] {
        case "left":
            if let value = states[target.id]?.left { return value + offset }
            if let inner = target.leftExpr, let value = evaluate(inner, depth: depth + 1) { return value + offset }
            return target.left + offset
        case "top":
            if let value = states[target.id]?.top { return value + offset }
            if let inner = target.topExpr, let value = evaluate(inner, depth: depth + 1) { return value + offset }
            return target.top + offset
        case "width": return target.width.map { $0 + offset }
        case "height": return target.height.map { $0 + offset }
        default: return nil
        }
    }

    // MARK: Properties scripts can read and write

    /// The widgets (anywhere in the tree) that belong to an element.
    func specs(ownedBy id: String) -> [WidgetSpec] {
        var found: [WidgetSpec] = []
        for scene in scenes {
            for node in scene.allNodes { found += node.specs.filter { $0.owner == id } }
        }
        return found
    }

    /// A property as set at run time, or else the layout's own value.
    func prop(_ id: String, _ key: String) -> String? {
        props[id]?[key] ?? nodes[id]?.props[key]
    }

    func setProp(_ id: String, _ key: String, _ value: String) {
        guard nodes[id] != nil else { return }
        var entry = props[id] ?? [:]
        entry[key] = value
        props[id] = entry
    }

    /// The words a text widget should show: what a script set, else the layout's own.
    func text(for id: String?) -> String? {
        guard let id else { return nil }
        return props[id]?["value"]
    }

    /// A slider's current value in its own units (e.g. -14...14), set by script or by dragging.
    func number(_ id: String, _ key: String, default fallback: Double) -> Double {
        prop(id, key).flatMap { Double($0) } ?? fallback
    }

    /// Whether the skin or its script has switched an element off. nil = never touched.
    func enabledOverride(_ id: String?) -> Bool? {
        guard let id else { return nil }
        return states[id]?.enabled
    }

    func initiallyEnabled(_ id: String?) -> Bool {
        guard let id, let node = nodes[id] else { return true }
        return states[id]?.enabled ?? node.enabled
    }

    func log(_ message: String) {
        scriptLog.append(message)
        if scriptLog.count > 200 { scriptLog.removeFirst(scriptLog.count - 200) }
    }

    // MARK: Running the skin's script

    /// Which skins the user has agreed to run script for (everything they import themselves).
    static func scriptsAllowed(_ skinID: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: "scriptSkins") ?? []).contains(skinID)
    }

    static func setScriptsAllowed(_ skinID: String, _ allowed: Bool) {
        var list = Set(UserDefaults.standard.stringArray(forKey: "scriptSkins") ?? [])
        if allowed { list.insert(skinID) } else { list.remove(skinID) }
        UserDefaults.standard.set(Array(list).sorted(), forKey: "scriptSkins")
    }

    /// Starts (or restarts) what follows the player for this skin: the live `wmpprop:` bindings, and the
    /// skin's script if it has one and the user allows it.
    func startScripts(skin: Skin, engine: PlayerEngine, appState: AppState) {
        lastStart = (skin, engine, appState)
        host?.stop()
        host = nil
        scriptsRunning = false
        scriptLog = []
        let allowed = Self.scriptsAllowed(skin.id)
        let files = allowed ? (skin.manifest.widgets?.scripts ?? []) : []
        let newHost = ScriptHost(runtime: self)
        _ = newHost.start(directory: skin.directory, scripts: files, engine: engine, appState: appState)
        guard newHost.isUseful else { return }
        host = newHost
        scriptsRunning = newHost.hasContext
    }

    /// Turns the script on or off for the current skin and starts over.
    func setScriptsEnabled(_ enabled: Bool) {
        guard let last = lastStart else { return }
        Self.setScriptsAllowed(last.skin.id, enabled)
        reset()
        startScripts(skin: last.skin, engine: last.engine, appState: last.appState)
    }

    /// Runs a click handler through the script engine. Returns true if the script handled it
    /// (so the caller shouldn't also do its built-in action).
    func runClick(_ code: String?) -> Bool {
        guard let code, !code.isEmpty, let host else { return false }
        return host.runClick(code)
    }

    /// A slider the user dragged: store the value, then let the script react (`value_onchange`).
    func userSetValue(_ id: String, _ value: Double) {
        setProp(id, "value", ScriptHost.format(value))
        host?.fire(id: id, event: "value_onchange")
    }

    var hasScript: Bool { host != nil }
}
