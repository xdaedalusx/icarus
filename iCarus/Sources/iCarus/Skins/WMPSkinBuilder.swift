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
    /// Elements the skin keeps hidden until a script shows them (panes, pop-ups).
    var hiddenCount: Int
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
        /// The view's own background picture: the "up" state for button groups that name no picture.
        var backdrop: String?
        /// id -> (left, top) relative to its parent, so "jscript:other.top+21" can be resolved.
        var ids: [String: (left: Double, top: Double)] = [:]

        mutating func skip(_ what: String) { skipped[what, default: 0] += 1 }

        mutating func add(_ label: String, _ make: (String) -> WidgetSpec) {
            specs.append(make("w\(specs.count)-\(label)"))
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
                      into folder: URL) throws -> WMPBuiltSkin {
        guard let view = root.allNodes.first(where: { $0.tag == "view" }) else { throw BuildError.noView }

        var context = Context()
        for image in artwork.images { context.images[key(image.source)] = image }
        context.groups = artwork.buttonGroups
        context.backdrop = view.attr("backgroundimage") ?? view.attr("image")

        // Window size: the layout's, or else the size of its background picture.
        let backdrop = context.image(view.attr("backgroundimage") ?? view.attr("image"))
        guard let width = number(view.attr("width")) ?? backdrop.map({ Double($0.width) }),
              let height = number(view.attr("height")) ?? backdrop.map({ Double($0.height) }),
              width > 0, height > 0 else { throw BuildError.noView }
        emit(view, originX: 0, originY: 0, context: &context)
        guard !context.specs.isEmpty else { throw BuildError.noArtwork }

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
                                  widgets: context.specs, showsFaceplate: false, shaped: true))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: folder.appendingPathComponent("skin.json"))

        var lines = context.skipped.sorted { $0.key < $1.key }.map { entry in
            entry.value > 1 ? "\(entry.key) ×\(entry.value)" : entry.key
        }
        if context.unresolved > 0 {
            lines.append("\(context.unresolved) position(s) worked out by script, placed at 0")
        }
        return WMPBuiltSkin(id: id, widgetCount: context.specs.count, controlCount: context.controls,
                            canvas: (Int(width), Int(height)), skipped: lines, hiddenCount: context.hidden)
    }

    // MARK: Walking the layout

    /// Elements whose picture only appears in some state (a script decides), so they stay out.
    private static let stateDriven: Set<String> = ["returnbutton"]

    /// Video is a real window in WMP, so it always sits above the skin's picture whatever its zIndex.
    private static func z(_ node: WMSNode) -> Int {
        let value = Int(number(node.attr("zindex")) ?? 0)
        return node.tag == "video" ? max(value, 0) : value
    }

    /// Adds `node`'s own picture / control and its children's, bottom to top.
    private static func emit(_ node: WMSNode, originX: Double, originY: Double, context: inout Context) {
        let x = originX + coordinate(node.attr("left"), .left, &context)
        let y = originY + coordinate(node.attr("top"), .top, &context)

        // Remember named children's positions first, so later siblings can refer to them.
        for child in node.children {
            if let id = child.attr("id")?.lowercased() {
                context.ids[id] = (resolve(child.attr("left"), .left, context) ?? 0,
                                   resolve(child.attr("top"), .top, context) ?? 0)
            }
        }

        // Stable sort by zIndex (document order breaks ties).
        let ordered = node.children.enumerated().sorted { a, b in
            z(a.element) != z(b.element) ? z(a.element) < z(b.element) : a.offset < b.offset
        }.map { $0.element }

        for child in ordered where z(child) < 0 {
            visit(child, originX: x, originY: y, context: &context)
        }
        drawOwn(node, x: x, y: y, context: &context)
        for child in ordered where z(child) >= 0 {
            visit(child, originX: x, originY: y, context: &context)
        }
    }

    private static func coordinate(_ text: String?, _ axis: Axis, _ context: inout Context) -> Double {
        guard text != nil else { return 0 }
        if let value = resolve(text, axis, context) { return value }
        context.unresolved += 1
        return 0
    }

    private static func visit(_ node: WMSNode, originX: Double, originY: Double, context: inout Context) {
        if node.attr("visible")?.lowercased() == "false" {
            context.hidden += node.allNodes.count
            return
        }
        if stateDriven.contains(node.tag) { context.hidden += 1; return }
        emit(node, originX: originX, originY: originY, context: &context)
    }

    /// Tags that only organise the layout; they're never "skipped" content.
    private static let organising: Set<String> = [
        "view", "subview", "theme", "player", "equalizersettings", "effects",
        "button", "buttongroup", "seekslider", "volumeslider", "balanceslider", "slider",
        "progressbar", "customslider", "video", "controls",
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
        case "statustext":
            drawText(node, binding: .trackTitle, x: x, y: y, context: &context)
        case "currentpositiontext":
            drawText(node, binding: .positionTime, x: x, y: y, context: &context)
        case "text":
            if let binding = textBinding(node.attr("value")) {
                drawText(node, binding: binding, x: x, y: y, context: &context)
            } else if let value = node.attr("value"), !value.isEmpty {
                context.skip("text label")
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
            if let action = binding(for: element),
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
            context.controls += 1
            context.add(label) { id in
                WidgetSpec(id: id, kind: .imageButton, binding: action,
                           x: x + Double(rect.x) + Double(rect.width) / 2,
                           y: y + Double(rect.y) + Double(rect.height) / 2,
                           width: Double(rect.width), height: Double(rect.height),
                           image: up, hoverImage: hover, downImage: down, disabledImage: disabled,
                           crop: [Double(rect.x), Double(rect.y), Double(rect.width), Double(rect.height)])
            }
        }
    }

    /// A single (non-grouped) button whose click we recognise; any other button stays a picture.
    private static func drawButton(_ node: WMSNode, x: Double, y: Double, context: inout Context) {
        let clicks = node.attr("onclick")
        guard let image = context.image(node.attr("image")) else { return }
        guard let action = action(forClick: clicks) else {
            if let clicks, !clicks.trimmingCharacters(in: .whitespaces).isEmpty,
               node.attr("enabled")?.lowercased() != "false" {
                context.skip(describe(node))
            }
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
                       image: up, hoverImage: hover, downImage: down, disabledImage: disabled)
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

    private static func drawText(_ node: WMSNode, binding: WidgetBinding, x: Double, y: Double,
                                 context: inout Context) {
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
        context.add(binding.rawValue) { id in
            WidgetSpec(id: id, kind: .display, binding: binding,
                       x: x + width / 2, y: y + height / 2, width: width, height: height,
                       fontSize: size, style: "plain",
                       textColor: color ?? "#0A1633", align: align)
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
