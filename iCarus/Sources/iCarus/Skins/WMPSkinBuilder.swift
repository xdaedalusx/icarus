import Foundation

// Pieces 3 and 4 of the WMP importer: turn the converted artwork into an installable iCarus
// skin that looks like the original AND has working transport buttons, seek slider and
// title / time text. (EQ / playlist / visualizer buttons come in piece 5.)
//
// How WMP stacks things: an element's children are drawn above the element's own picture,
// in `zIndex` order (ties keep document order). A child with a NEGATIVE zIndex goes
// underneath its parent's picture instead, which is how Cerulean's "eye" shows through
// the hole in the face.

struct WMPBuiltSkin {
    var id: String
    var widgetCount: Int
    var controlCount: Int
    var canvas: (width: Int, height: Int)
    /// What the skin has that iCarus left out, one short line each.
    var skipped: [String]
    /// Elements the skin keeps hidden until a script shows them (panes, pop-ups). They are kept.
    var hiddenCount: Int
    /// How many views (windows / pages) the layout has.
    var viewCount: Int
    /// How many elements were kept in the layout's tree.
    var nodeCount: Int
    /// Script files kept with the skin (they run in a sandbox, only for skins you import yourself).
    var scriptCount: Int
}

enum WMPSkinBuilder {
    enum BuildError: LocalizedError {
        case noView, noArtwork
        var errorDescription: String? {
            switch self {
            case .noView: return "The layout has no <view> with a width and height."
            case .noArtwork: return "None of the layout's pictures could be placed."
            }
        }
    }

    /// Mutable state while walking the layout.
    private struct Context {
        var images: [String: WMPConvertedImage] = [:]
        var groups: [WMPButtonGroup] = []
        var specs: [WidgetSpec] = []
        var controls = 0
        var skipped: [String: Int] = [:]
        var hidden = 0
        var unresolved = 0
        var serial = 0
        var nodeCount = 0
        var usedIDs = Set<String>()
        /// The skin has script files, so buttons with other click handlers can be wired to them.
        var hasScript = false
        /// Ids handed out in advance (so a button group can name its buttons before they're built).
        var idByNode: [ObjectIdentifier: String] = [:]
        var currentID = ""

        mutating func assignID(_ node: WMSNode, forced: String? = nil) -> String {
            if let known = idByNode[ObjectIdentifier(node)] { return known }
            var id = forced ?? node.attr("id")?.lowercased() ?? ""
            if id.isEmpty { id = "n\(nodeCount + usedIDs.count + 1)" }
            if usedIDs.contains(id) { id += "-\(usedIDs.count + 1)" }
            usedIDs.insert(id)
            idByNode[ObjectIdentifier(node)] = id
            return id
        }
        /// The view's own background picture: the "up" state for button groups that name no picture.
        var backdrop: String?
        /// id -> (left, top) relative to its parent, so "jscript:other.top+21" can be resolved.
        var ids: [String: (left: Double, top: Double)] = [:]

        mutating func skip(_ what: String) { skipped[what, default: 0] += 1 }

        mutating func add(_ label: String, _ make: (String) -> WidgetSpec) {
            serial += 1
            specs.append(make("w\(serial)-\(label)"))
        }
        func file(_ name: String?) -> String? {
            guard let name else { return nil }
            return images[WMPSkinBuilder.key(name)]?.output
        }
        func image(_ name: String?) -> WMPConvertedImage? {
            guard let name else { return nil }
            return images[WMPSkinBuilder.key(name)]
        }
    }

    // MARK: Build

    /// Writes `skin.json` into `folder`, next to the converted PNGs.
    static func build(layout root: WMSNode,
                      artwork: WMPArtworkResult,
                      name: String,
                      author: String?,
                      scripts: [String] = [],
                      into folder: URL) throws -> WMPBuiltSkin {
        guard root.allNodes.contains(where: { $0.tag == "view" }) else { throw BuildError.noView }

        var context = Context()
        for image in artwork.images { context.images[key(image.source)] = image }
        context.groups = artwork.buttonGroups
        context.hasScript = !scripts.isEmpty

        // Window size: the layout's, or else the size of its background picture.
        func size(of view: WMSNode, fallback: (Double, Double)?) -> (Double, Double)? {
            context.backdrop = view.attr("backgroundimage") ?? view.attr("image")
            let picture = context.image(context.backdrop)
            let w = number(view.attr("width")) ?? picture.map { Double($0.width) } ?? fallback?.0
            let h = number(view.attr("height")) ?? picture.map { Double($0.height) } ?? fallback?.1
            guard let w, let h, w > 0, h > 0 else { return nil }
            return (w, h)
        }

        // Every <view> becomes a scene; the first is the main window.
        let views = root.allNodes.filter { $0.tag == "view" }
        var scenes: [SceneLayout] = []
        var mainSize: (Double, Double)?
        for (index, view) in views.enumerated() {
            guard let dimensions = size(of: view, fallback: mainSize) else {
                if index == 0 { throw BuildError.noView }
                continue
            }
            if index == 0 { mainSize = dimensions }
            context.ids = [:]
            let sceneID = index == 0 ? "main" : (view.attr("id")?.lowercased() ?? "view\(index + 1)")
            let node = buildNode(view, forcedID: "view:" + sceneID, context: &context)
            scenes.append(SceneLayout(id: sceneID, canvasWidth: dimensions.0, canvasHeight: dimensions.1, root: node))
        }
        guard let (width, height) = mainSize, !scenes.isEmpty else { throw BuildError.noView }
        guard context.serial > 0 else { throw BuildError.noArtwork }

        let slug = String(name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let id = "wmp." + slug
        let manifest = SkinManifest(
            id: id,
            name: name.prefix(1).uppercased() + name.dropFirst(),
            author: author ?? "Unknown",
            version: "1.0",
            layout: .widgets,
            colors: .init(background: "#101014", surface: "#1C1C22", accent: "#4A90D9",
                          text: "#F5F5F7", secondaryText: "#98989D"),
            typography: .init(design: "default", titleSize: 14, bodySize: 11),
            metrics: .init(cornerRadius: 0, spacing: 8, controlSize: 24,
                           windowWidth: width, windowHeight: height),
            backgroundImage: nil,
            widgets: WidgetLayout(canvasWidth: width, canvasHeight: height,
                                  widgets: [], showsFaceplate: false, shaped: true, scenes: scenes,
                                  scripts: scripts.isEmpty ? nil : scripts))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: folder.appendingPathComponent("skin.json"))

        var lines = context.skipped.sorted { $0.key < $1.key }.map { entry in
            entry.value > 1 ? "\(entry.key) ×\(entry.value)" : entry.key
        }
        if context.unresolved > 0 {
            lines.append("\(context.unresolved) position(s) worked out by script, placed at 0")
        }
        return WMPBuiltSkin(id: id, widgetCount: context.serial, controlCount: context.controls,
                            canvas: (Int(width), Int(height)), skipped: lines, hiddenCount: context.hidden,
                            viewCount: scenes.count, nodeCount: context.nodeCount, scriptCount: scripts.count)
    }

    // MARK: Walking the layout

    /// Elements whose picture only appears in some state (a script decides): kept, but hidden to start.
    private static let hiddenAtStart: Set<String> = ["returnbutton"]

    /// "jscript:bass.top+21;" -> "bass.top+21". Plain numbers and blanks give nil.
    private static func expression(_ text: String?) -> String? {
        guard let text else { return nil }
        let value = text.trimmingCharacters(in: .whitespaces)
        guard value.lowercased().hasPrefix("jscript:") else { return nil }
        let body = value.dropFirst("jscript:".count).replacingOccurrences(of: ";", with: "")
            .trimmingCharacters(in: .whitespaces)
        return body.isEmpty ? nil : body
    }

    /// Attributes that are event handlers (onclick, onload, value_onchange, ...). Kept for scripts.
    private static func eventHandlers(_ node: WMSNode) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in node.attributes where key.hasPrefix("on") || key.contains("_on") {
            result[key] = value
        }
        return result
    }

    /// Turns a layout element (and everything inside it) into a scene node. Nothing is dropped:
    /// hidden elements stay in the tree with `visible = false`.
    private static func buildNode(_ node: WMSNode, forcedID: String? = nil,
                                  context: inout Context) -> SceneNode {
        // A unique, lower-cased id (scripts find elements by name).
        let id = context.assignID(node, forced: forcedID)
        context.nodeCount += 1
        // Hand out the children's ids now, so this element's buttons can be tied to them.
        for child in node.children { _ = context.assignID(child) }

        var scene = SceneNode(id: id, tag: node.tag)
        scene.name = forcedID == nil ? node.attr("id") : nil
        for key in ["value", "tooltip", "uptooltip", "min", "max", "enabled", "visible",
                    "currenteffecttype", "currentpreset", "timerinterval"] {
            if let value = node.attr(key) { scene.props[key] = value }
        }
        scene.left = coordinate(node.attr("left"), .left, &context)
        scene.top = coordinate(node.attr("top"), .top, &context)
        scene.leftExpr = expression(node.attr("left"))
        scene.topExpr = expression(node.attr("top"))
        scene.width = number(node.attr("width"))
        scene.height = number(node.attr("height"))
        scene.zIndex = Int(number(node.attr("zindex")) ?? 0)
        scene.visible = node.attr("visible")?.lowercased() != "false" && !hiddenAtStart.contains(node.tag)
        scene.enabled = node.attr("enabled")?.lowercased() != "false"
        scene.events = eventHandlers(node)
        if !scene.visible { context.hidden += 1 }

        // Remember named children's positions first, so later siblings can refer to them.
        for child in node.children {
            if let childID = child.attr("id")?.lowercased() {
                context.ids[childID] = (resolve(child.attr("left"), .left, context) ?? 0,
                                        resolve(child.attr("top"), .top, context) ?? 0)
            }
        }

        // This element's own drawing, placed relative to its own corner.
        let outer = context.specs
        context.specs = []
        context.currentID = id
        drawOwn(node, x: 0, y: 0, context: &context)
        // Every widget belongs to an element (unless drawOwn named a more specific one).
        scene.specs = context.specs.map { spec in
            var copy = spec
            if copy.owner == nil { copy.owner = id }
            return copy
        }
        context.specs = outer

        scene.children = node.children.map { buildNode($0, context: &context) }
        return scene
    }

    private static func coordinate(_ text: String?, _ axis: Axis, _ context: inout Context) -> Double {
        guard text != nil else { return 0 }
        if let value = resolve(text, axis, context) { return value }
        context.unresolved += 1
        return 0
    }

    /// Tags that only organise the layout; they're never "skipped" content.
    private static let organising: Set<String> = [
        "view", "subview", "theme", "player", "equalizersettings", "effects",
        "button", "buttongroup", "seekslider", "volumeslider", "balanceslider", "slider",
        "progressbar", "customslider", "video", "controls", "itemsplaylist",
        "statustext", "currentpositiontext", "text"
    ]

    /// Draws what a node itself is: a button group, a slider, a text, or just a picture.
    private static func drawOwn(_ node: WMSNode, x: Double, y: Double, context: inout Context) {
        switch node.tag {
        case "buttongroup":
            drawButtonGroup(node, x: x, y: y, context: &context)
        case "seekslider", "volumeslider", "balanceslider", "slider", "progressbar":
            drawSlider(node, x: x, y: y, context: &context)
        case "customslider":
            drawFilmstrip(node, x: x, y: y, context: &context)
        case "video":
            drawVideo(node, x: x, y: y, context: &context)
        case "itemsplaylist":
            drawPlaylist(node, x: x, y: y, context: &context)
        case "statustext":
            drawText(node, binding: .trackTitle, x: x, y: y, context: &context)
        case "currentpositiontext":
            drawText(node, binding: .positionTime, x: x, y: y, context: &context)
        case "text":
            if let binding = textBinding(node.attr("value")) {
                drawText(node, binding: binding, x: x, y: y, context: &context)
            } else if (node.attr("value") ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                // No words yet: a script fills this in (e.g. the scrolling song title).
                drawText(node, binding: .staticText, literal: "", x: x, y: y, context: &context)
            } else if let value = node.attr("value")?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
                let lower = value.lowercased()
                if lower.hasPrefix("wmpprop:") {
                    // A live value from the player; the script host keeps its words up to date.
                    drawText(node, binding: .staticText, literal: "", x: x, y: y, context: &context)
                } else if lower.hasPrefix("jscript:") {
                    context.skip("text from script")
                } else {
                    // A fixed label ("Bass", "Volume", ...).
                    drawText(node, binding: .staticText, literal: value, x: x, y: y, context: &context)
                }
            }
        case "effects":
            drawVisualizer(node, x: x, y: y, context: &context)
        case "button":
            drawButton(node, x: x, y: y, context: &context)
        default:
            if !organising.contains(node.tag) { context.skip(node.tag) }
            drawPicture(node, x: x, y: y, context: &context)
        }
    }

    private static func drawPicture(_ node: WMSNode, x: Double, y: Double, context: inout Context) {
        guard let image = context.image(node.attr("backgroundimage") ?? node.attr("image")) else { return }
        context.add((image.output as NSString).deletingPathExtension) { id in
            WidgetSpec(id: id, kind: .image, binding: .play,   // binding is ignored for pictures
                       x: x + Double(image.width) / 2, y: y + Double(image.height) / 2,
                       width: Double(image.width), height: Double(image.height),
                       image: image.output)
        }
    }

    // MARK: Actions

    /// What a click handler (JScript text) is asking for, if it's something iCarus can do.
    private static func action(forClick raw: String?) -> WidgetBinding? {
        let c = (raw ?? "").lowercased().replacingOccurrences(of: " ", with: "")
        if c.isEmpty { return nil }
        if c.contains("view.minimize") { return .minimizeWindow }
        if c.contains("view.close") { return .closeWindow }
        if c.contains("controls.pause") { return .pause }
        if c.contains("controls.stop") { return .stop }
        if c.contains("controls.next") { return .next }
        if c.contains("controls.previous") { return .previous }
        if c.contains("controls.play") && !c.contains("playlist") { return .play }
        if c.contains("effects.previous") { return .previousVisualization }
        if c.contains("controls.fastreverse") { return .skipBack }
        if c.contains("controls.fastforward") { return .skipForward }
        if c.contains("opendialog") { return .openFiles }
        if c.contains("playview") { return .showPlaylist }
        if c.contains("effects.next") || c.contains("viseffects.next") || c.contains("nextpreset") { return .nextVisualization }
        if c.contains("audpane") || c.contains("equalizer") { return .showEqualizer }
        if c.contains("plpane") || c.contains("playlist") { return .showPlaylist }
        if c.contains("shuffle") { return .shuffle }
        if c.contains("repeat") || c.contains("loop") { return .repeatMode }
        return nil
    }

    private static func binding(for element: WMSNode) -> WidgetBinding? {
        switch element.tag {
        case "prevelement": return .previous
        case "playelement": return .play
        case "pauseelement": return .pause
        case "stopelement": return .stop
        case "nextelement": return .next
        case "shuffleelement": return .shuffle
        case "repeatelement": return .repeatMode
        case "rewelement": return .skipBack
        case "ffwdelement": return .skipForward
        case "buttonelement": return action(forClick: element.attr("onclick"))
        default: return nil
        }
    }

    private static func describe(_ node: WMSNode) -> String {
        let name = node.attr("uptooltip") ?? node.attr("tooltip") ?? node.attr("id") ?? node.tag
        return "\(name) (no matching action)"
    }

    // MARK: Buttons

    private static func drawButtonGroup(_ node: WMSNode, x: Double, y: Double, context: inout Context) {
        let mapKey = key(node.attr("mappingimage") ?? "")
        let imageKey = key(node.attr("image") ?? "")
        let group = context.groups.first {
            key($0.mappingImage) == mapKey && key($0.image ?? "") == imageKey
        }
        let elements = node.children.filter { $0.attr("mappingcolor") != nil }

        // Pair each element with its box in the strip and the action it should do.
        var working: [(WMSNode, WidgetBinding, PixelRect)] = []
        for element in elements {
            let color = (element.attr("mappingcolor") ?? "").uppercased()
            let click = element.attr("onclick")?.trimmingCharacters(in: .whitespaces) ?? ""
            // A known action, or (if the skin has script) whatever its click handler does.
            let action = binding(for: element) ?? (context.hasScript && !click.isEmpty ? WidgetBinding.scriptOnly : nil)
            if let action,
               let rect = group?.regions.first(where: { $0.mappingColor == color })?.rect {
                working.append((element, action, rect))
            } else {
                context.skip(describe(element))
            }
        }

        // If some buttons aren't wired, keep the whole strip as a picture so their icons still
        // show; fully wired groups are drawn by their buttons alone.
        if (working.count < elements.count || working.isEmpty), node.attr("image") != nil {
            drawPicture(node, x: x, y: y, context: &context)
        }

        // No `image` means the buttons sit on the view's own background picture.
        let up = context.file(node.attr("image")) ?? context.file(context.backdrop)
        let hover = context.file(node.attr("hoverimage"))
        let down = context.file(node.attr("downimage")) ?? hover
        let disabled = context.file(node.attr("disabledimage"))
        for (element, action, rect) in working {
            let label = (element.attr("id") ?? element.tag)
            let ownerID = context.idByNode[ObjectIdentifier(element)]
            context.controls += 1
            context.add(label) { id in
                WidgetSpec(id: id, kind: .imageButton, binding: action,
                           x: x + Double(rect.x) + Double(rect.width) / 2,
                           y: y + Double(rect.y) + Double(rect.height) / 2,
                           width: Double(rect.width), height: Double(rect.height),
                           image: up, hoverImage: hover, downImage: down, disabledImage: disabled,
                           crop: [Double(rect.x), Double(rect.y), Double(rect.width), Double(rect.height)],
                           owner: ownerID, onclick: element.attr("onclick"),
                           tooltip: tooltip(element))
            }
        }
    }

    /// A single (non-grouped) button whose click we recognise; any other button stays a picture.
    private static func drawButton(_ node: WMSNode, x: Double, y: Double, context: inout Context) {
        let clicks = node.attr("onclick")
        guard let image = context.image(node.attr("image")) else { return }
        let hasClick = !(clicks ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        guard let action = action(forClick: clicks) ?? (context.hasScript && hasClick ? WidgetBinding.scriptOnly : nil) else {
            if hasClick, node.attr("enabled")?.lowercased() != "false" { context.skip(describe(node)) }
            drawPicture(node, x: x, y: y, context: &context)
            return
        }
        let up = image.output
        let hover = context.file(node.attr("hoverimage"))
        let down = context.file(node.attr("downimage"))
        let disabled = context.file(node.attr("disabledimage"))
        context.controls += 1
        context.add(action.rawValue) { id in
            WidgetSpec(id: id, kind: .imageButton, binding: action,
                       x: x + Double(image.width) / 2, y: y + Double(image.height) / 2,
                       width: Double(image.width), height: Double(image.height),
                       image: up, hoverImage: hover, downImage: down, disabledImage: disabled,
                       onclick: clicks, tooltip: tooltip(node))
        }
    }

    /// The skin's visualizer window: bare bars/wave/radial over the artwork behind it.
    private static func drawVisualizer(_ node: WMSNode, x: Double, y: Double, context: inout Context) {
        guard let w = number(node.attr("width")), let h = number(node.attr("height")) else { return }
        context.controls += 1
        context.add("visualizer") { id in
            WidgetSpec(id: id, kind: .visualization, binding: .play,
                       x: x + w / 2, y: y + h / 2, width: w, height: h,
                       style: "auto", bare: true)
        }
    }

    // MARK: Sliders

    private static func sliderBinding(_ node: WMSNode) -> WidgetBinding? {
        switch node.tag {
        case "seekslider", "progressbar": return .seek
        case "volumeslider": return .volume
        case "balanceslider": return .balance
        default: break
        }
        // A slider whose change handler is script (e.g. bass/treble that script mixes into 10 bands)
        // keeps its value on the element, and the script does the rest.
        if node.tag == "slider", node.attr("value_onchange") != nil { return .elementValue }
        let value = (node.attr("value") ?? "").lowercased().replacingOccurrences(of: " ", with: "")
        if value.contains("currentposition") { return .seek }
        if value.contains("settings.volume") { return .volume }
        if value.contains("balance") { return .balance }
        if let range = value.range(of: "gainlevel") {
            let digits = value[range.upperBound...].prefix { $0.isNumber }
            if let band = Int(digits), (1...10).contains(band) { return WidgetBinding(rawValue: "eqBand\(band)") }
        }
        return nil
    }

    private static func drawSlider(_ node: WMSNode, x: Double, y: Double, context: inout Context) {
        guard let action = sliderBinding(node) else {
            context.skip("slider (no matching control)")
            return
        }
        guard let track = context.image(node.attr("backgroundimage")) else {
            context.skip("slider without a picture")
            return
        }
        let thumb = context.image(node.attr("thumbimage"))
        let w = Double(track.width), h = Double(track.height)
        let vertical = h > w
        // The handle's centre can't go into the end caps (borderSize) or past half its own width.
        let border = number(node.attr("bordersize")) ?? 0
        let thumbLength = Double(vertical ? (thumb?.height ?? 0) : (thumb?.width ?? 0))
        // A progress picture is only used if the skin says so.
        let wantsFill = node.attr("useforegroundprogress")?.lowercased() != "false"
        let thumbDown = context.file(node.attr("thumbdownimage"))
        let fill = wantsFill ? context.file(node.attr("foregroundimage")) : nil
        context.controls += 1
        context.add(node.tag) { id in
            WidgetSpec(id: id, kind: .imageSlider, binding: action,
                       x: x + w / 2, y: y + h / 2, width: w, height: h,
                       image: track.output,
                       thumbImage: thumb?.output,
                       thumbDownImage: thumbDown,
                       fillImage: fill,
                       vertical: vertical ? true : nil,
                       inset: border + thumbLength / 2)
        }
    }

    /// A control drawn as a strip of pictures, one per position (e.g. a volume dial).
    private static func drawFilmstrip(_ node: WMSNode, x: Double, y: Double, context: inout Context) {
        guard let action = sliderBinding(node) else {
            context.skip("custom slider (no matching control)")
            return
        }
        guard let strip = context.image(node.attr("image")),
              let map = context.image(node.attr("positionimage")), map.width > 0 else {
            context.skip("custom slider without its pictures")
            return
        }
        let w = Double(map.width), h = Double(map.height)
        let frames = max(strip.width / map.width, 1)
        context.controls += 1
        context.add("customslider") { id in
            WidgetSpec(id: id, kind: .filmstripSlider, binding: action,
                       x: x + w / 2, y: y + h / 2, width: w, height: h,
                       image: strip.output, positionImage: map.output, frames: frames)
        }
    }

    /// The skin's video window: shows the picture only while a video plays.
    private static func drawVideo(_ node: WMSNode, x: Double, y: Double, context: inout Context) {
        guard let w = number(node.attr("width")), let h = number(node.attr("height")) else { return }
        context.controls += 1
        context.add("video") { id in
            WidgetSpec(id: id, kind: .videoPane, binding: .play,
                       x: x + w / 2, y: y + h / 2, width: w, height: h, bare: true)
        }
    }

    /// The skin's own list of what's queued: a panel the size of the element. Double-click plays an item.
    private static func drawPlaylist(_ node: WMSNode, x: Double, y: Double, context: inout Context) {
        guard let w = number(node.attr("width")), let h = number(node.attr("height")) else { return }
        func hex(_ attribute: String, _ fallback: String) -> String {
            let raw = (node.attr(attribute) ?? "").trimmingCharacters(in: .whitespaces)
            return raw.hasPrefix("#") ? raw : (colorNames[raw.lowercased()] ?? fallback)
        }
        let points = number(node.attr("fontsize")) ?? 9
        context.controls += 1
        context.add("playlist") { id in
            WidgetSpec(id: id, kind: .playlistPane, binding: .play,
                       x: x + w / 2, y: y + h / 2, width: w, height: h,
                       fontSize: (points * 4 / 3).rounded(),
                       textColor: hex("foregroundcolor", "#FFFFFF"),
                       fontFace: fontFace(node), backColor: hex("backgroundcolor", "#000000"))
        }
    }

    private static func tooltip(_ node: WMSNode) -> String? {
        let tip = (node.attr("uptooltip") ?? node.attr("tooltip") ?? "").trimmingCharacters(in: .whitespaces)
        return tip.isEmpty ? nil : tip
    }

    private static func fontFace(_ node: WMSNode) -> String? {
        let face = (node.attr("fontface") ?? "").trimmingCharacters(in: .whitespaces)
        return face.isEmpty ? nil : face
    }

    // MARK: Text

    /// Which player text a `<text value="wmpprop:...">` shows.
    private static func textBinding(_ value: String?) -> WidgetBinding? {
        let v = (value ?? "").lowercased().replacingOccurrences(of: " ", with: "")
        guard v.hasPrefix("wmpprop:") else { return nil }
        if v.contains("currentpositionstring") { return .positionTime }
        if v.contains("durationstring") { return .durationTime }
        if v.contains("author") || v.contains("artist") { return .trackArtist }
        if v.contains("currentmedia.name") || v.contains("media.name") || v.contains("title") { return .trackTitle }
        return nil
    }

    private static let colorNames: [String: String] = [
        "white": "#FFFFFF", "black": "#000000", "red": "#FF0000", "yellow": "#FFFF00",
        "blue": "#0000FF", "lime": "#00FF00", "green": "#008000", "gray": "#808080",
        "silver": "#C0C0C0", "navy": "#000080", "orange": "#FFA500"
    ]

    private static func drawText(_ node: WMSNode, binding: WidgetBinding, literal: String? = nil,
                                 x: Double, y: Double, context: inout Context) {
        let width = number(node.attr("width")) ?? 100
        let points = number(node.attr("fontsize")) ?? 9
        let size = (points * 4 / 3).rounded()       // WMP sizes are points; the canvas is pixels
        let height = number(node.attr("height")) ?? (size * 1.4).rounded(.up)
        let align: String
        switch (node.attr("justification") ?? "").lowercased() {
        case "right": align = "trailing"
        case "center": align = "center"
        default: align = "leading"
        }
        let rawColor = (node.attr("foregroundcolor") ?? "").trimmingCharacters(in: .whitespaces)
        let color = rawColor.hasPrefix("#") ? rawColor : colorNames[rawColor.lowercased()]
        let face = fontFace(node)
        // scrolling="true" / "auto": long words slide past (scrollingAmount pixels every scrollingDelay ms).
        let scrolling = (node.attr("scrolling") ?? "false").lowercased()
        let scrolls = scrolling == "true" || scrolling == "auto"
        let amount = number(node.attr("scrollingamount")) ?? 3
        let delay = max(number(node.attr("scrollingdelay")) ?? 100, 10)
        context.add(binding.rawValue) { id in
            WidgetSpec(id: id, kind: .display, binding: binding,
                       x: x + width / 2, y: y + height / 2, width: width, height: height,
                       fontSize: size, style: "plain",
                       textColor: color ?? "#0A1633", align: align, text: literal,
                       onclick: node.attr("onclick"),
                       scrollSpeed: scrolls ? amount * 1000 / delay : nil,
                       fontFace: face)
        }
    }

    // MARK: Helpers

    fileprivate static func key(_ name: String) -> String {
        (name.trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent.lowercased()
    }

    /// A plain number, or nil for blanks and scripts.
    private static func number(_ text: String?) -> Double? {
        guard let text else { return nil }
        return Double(text.trimmingCharacters(in: .whitespaces))
    }

    fileprivate enum Axis { case left, top }

    /// A number, or a simple script like "jscript:bass.top+21;" (another element's position plus an offset).
    private static func resolve(_ text: String?, _ axis: Axis, _ context: Context) -> Double? {
        guard let text else { return nil }
        if let value = number(text) { return value }
        var body = text.trimmingCharacters(in: .whitespaces)
        guard body.lowercased().hasPrefix("jscript:") else { return nil }
        body = String(body.dropFirst("jscript:".count)).replacingOccurrences(of: ";", with: "")
            .replacingOccurrences(of: " ", with: "").lowercased()
        // <id>.<left|top> [+|- number]
        var offset = 0.0
        var reference = body
        if let plus = body.firstIndex(where: { $0 == "+" || $0 == "-" }) {
            reference = String(body[..<plus])
            guard let amount = Double(body[body.index(after: plus)...]) else { return nil }
            offset = body[plus] == "-" ? -amount : amount
        }
        let parts = reference.split(separator: ".")
        guard parts.count == 2, let target = context.ids[String(parts[0])] else { return nil }
        switch parts[1] {
        case "left": return target.left + offset
        case "top": return target.top + offset
        default: return nil
        }
    }
}
