import Foundation
import JavaScriptCore
import Combine
import AppKit

// Runs a skin's own script (JScript, which JavaScriptCore handles for what skins actually write)
// in a SANDBOX: a bare JavaScript context that can only see the objects built here. There is no file,
// network, or program access. The skin sees a small copy of the Windows Media Player object model:
//
//   player (openState, playState, currentMedia, controls, settings, launchURL), eq, view, theme,
//   and one object per named element in the layout (visible, enabled, zIndex, left, top, value,
//   moveTo(...), ...), plus the usual constants (osMediaOpen, psPlaying, ...).
//
// Everything a script does goes through get / set / call below, so what a skin can do is defined here.

/// Runs `body` on the main actor from code the compiler thinks is not on it. The script engine is only
/// ever used on the main thread, so this is safe; it just keeps the types honest.
private func onMainActor<T>(_ body: @MainActor () -> T) -> T {
    precondition(Thread.isMainThread, "Script engine must run on the main thread")
    return withoutActuallyEscaping(body) { escapable in
        unsafeBitCast(escapable, to: (() -> T).self)()
    }
}

@MainActor
final class ScriptHost {
    private unowned let runtime: SceneRuntime
    private weak var engine: PlayerEngine?
    private weak var appState: AppState?
    private var context: JSContext?
    private var bag = Set<AnyCancellable>()
    private var inUserEvent = false
    private var videoActive = false
    private var lastError: String?
    private var volumeBeforeMute: Float = 0.8

    init(runtime: SceneRuntime) { self.runtime = runtime }

    // MARK: Start / stop

    /// Starts the live bindings, and the script if there is one. Returns true if a script is running.
    func start(directory: URL?, scripts: [String], engine: PlayerEngine, appState: AppState) -> Bool {
        self.engine = engine
        self.appState = appState
        collectBindings()

        if !scripts.isEmpty, let directory, let context = JSContext() {
            self.context = context
            context.exceptionHandler = { [weak self] _, exception in
                let message = exception?.toString() ?? "script error"
                let line = exception?.objectForKeyedSubscript("line")?.toString() ?? "?"
                onMainActor { self?.lastError = message; self?.runtime.log("Error: \(message) (line \(line))") }
            }
            Self.install(on: context, host: self)

            // One JavaScript object per named element, under the spelling the layout used.
            for scene in runtime.scenes {
                for node in scene.allNodes {
                    guard let name = node.name, !name.isEmpty, Self.isIdentifier(name) else { continue }
                    _ = context.evaluateScript("if (typeof \(name) === 'undefined') { var \(name) = __element('\(node.id)'); }")
                }
            }

            var loaded = 0
            for file in scripts {
                let url = directory.appendingPathComponent((file as NSString).lastPathComponent)
                guard let code = try? String(contentsOf: url, encoding: .utf8) else {
                    runtime.log("Couldn't read \(file)")
                    continue
                }
                context.evaluateScript(code, withSourceURL: url)
                loaded += 1
            }
            runtime.log("Loaded \(loaded) script file(s).")
        }
        if !bindings.isEmpty { runtime.log("Following \(bindings.count) live player value(s).") }

        observePlayer(engine)
        refreshBindings()
        // The view's onload runs once everything is defined.
        fireAll(tag: "view", event: "onload")
        startViewTimers()
        return context != nil
    }

    /// True if there is anything for this host to do (a script, or values to keep in step).
    var isUseful: Bool { context != nil || !bindings.isEmpty }
    var hasContext: Bool { context != nil }

    func stop() {
        bag.removeAll()
        moves = [:]
        moveClock = nil
        timers = [:]
        context = nil
    }

    // MARK: Animation

    private struct Move {
        let fromX: Double, fromY: Double, toX: Double, toY: Double
        let start: Date
        let duration: Double
        let easing: String
    }
    private var moves: [String: Move] = [:]
    private var moveClock: AnyCancellable?

    /// Slides an element to a new place over `duration` seconds, then runs its onendmove.
    private func beginMove(_ id: String, x: Double?, y: Double?, duration: Double, easing: String) {
        guard let node = runtime.node(named: id) else { return }
        let fromX = runtime.left(node), fromY = runtime.top(node)
        let toX = x ?? fromX, toY = y ?? fromY
        moves[id] = nil
        if duration <= 0 {
            runtime.set(id, left: toX, top: toY)
            DispatchQueue.main.async { [weak self] in self?.fire(id: id, event: "onendmove") }
            return
        }
        moves[id] = Move(fromX: fromX, fromY: fromY, toX: toX, toY: toY,
                         start: Date(), duration: duration, easing: easing)
        if moveClock == nil {
            moveClock = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()
                .sink { [weak self] _ in self?.advanceMoves() }
        }
    }

    private func advanceMoves() {
        let now = Date()
        for (id, move) in Array(moves) {
            let t = min(1, now.timeIntervalSince(move.start) / move.duration)
            let e = Self.ease(t, move.easing)
            runtime.set(id, left: move.fromX + (move.toX - move.fromX) * e,
                        top: move.fromY + (move.toY - move.fromY) * e)
            if t >= 1 {
                moves[id] = nil
                fire(id: id, event: "onendmove")
            }
        }
        if moves.isEmpty { moveClock = nil }
    }

    nonisolated static func ease(_ t: Double, _ kind: String) -> Double {
        switch kind.lowercased() {
        case "linear": return t
        case "easein", "in": return t * t
        case "easeout", "out": return 1 - (1 - t) * (1 - t)
        default: return t * t * (3 - 2 * t)     // ease in and out
        }
    }

    // MARK: Timers (setTimeout / setInterval / a view's timerInterval)

    private var timers: [Int: AnyCancellable] = [:]
    private var nextTimer = 1
    private static let viewTimerBase = 1_000_000

    /// Returns a timer number, or 0 if the skin already has too many running.
    func addTimer(ms: Double, repeats: Bool) -> Int {
        guard timers.count < 64 else { return 0 }
        let id = nextTimer
        nextTimer += 1
        let interval = max(ms, 20) / 1000        // not faster than 50 times a second
        timers[id] = Timer.publish(every: interval, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.timerFired(id, repeats: repeats) }
        return id
    }

    func clearTimer(_ id: Int) { timers[id] = nil }

    private func timerFired(_ id: Int, repeats: Bool) {
        if !repeats { timers[id] = nil }
        _ = context?.objectForKeyedSubscript("__fire")?.call(withArguments: [id])
    }

    /// A view's timerInterval (milliseconds) with an ontimer handler: runs that handler repeatedly.
    private func startViewTimers(override: Double? = nil) {
        for key in timers.keys where key >= Self.viewTimerBase { timers[key] = nil }
        guard context != nil else { return }
        var slot = Self.viewTimerBase
        for scene in runtime.scenes {
            for node in scene.allNodes where node.tag == "view" && node.events["ontimer"] != nil {
                let ms = override ?? Double(node.props["timerinterval"] ?? "") ?? 0
                guard ms > 0 else { continue }
                let id = node.id
                timers[slot] = Timer.publish(every: max(ms, 20) / 1000, on: .main, in: .common).autoconnect()
                    .sink { [weak self] _ in _ = self?.fire(id: id, event: "ontimer") }
                slot += 1
            }
        }
    }

    // MARK: Events

    /// Runs the handler text stored on an element (e.g. "OnLoad();"). Returns true if it ran cleanly.
    @discardableResult
    func fire(id: String, event: String) -> Bool {
        guard let node = runtime.node(named: id), let code = node.events[event.lowercased()] else { return false }
        return run(code)
    }

    func fireAll(tag: String, event: String) {
        for scene in runtime.scenes {
            for node in scene.allNodes where node.tag == tag {
                if let code = node.events[event.lowercased()] { _ = run(code) }
            }
        }
    }

    /// A click on a widget: the handler runs as a user action (so, e.g., launchURL is allowed).
    func runClick(_ code: String) -> Bool {
        inUserEvent = true
        defer { inUserEvent = false }
        return run(code)
    }

    private func run(_ rawCode: String) -> Bool {
        guard let context else { return false }
        var code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if code.lowercased().hasPrefix("jscript:") { code = String(code.dropFirst("jscript:".count)) }
        lastError = nil
        context.evaluateScript(code)
        return lastError == nil
    }

    // MARK: Following the player

    private func observePlayer(_ engine: PlayerEngine) {
        engine.$isPlaying.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.fireAll(tag: "player", event: "playstate_onchange") }
            .store(in: &bag)
        engine.$currentIndex.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.mediaChanged() }
            .store(in: &bag)
        engine.$queue.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.mediaChanged() }
            .store(in: &bag)

        // Anything a live binding might follow.
        guard !bindings.isEmpty || hasControlsHandler else { return }
        let changes: [AnyPublisher<Void, Never>] = [
            engine.$volume.map { _ in () }.eraseToAnyPublisher(),
            engine.$balance.map { _ in () }.eraseToAnyPublisher(),
            engine.$eqGains.map { _ in () }.eraseToAnyPublisher(),
            engine.$eqEnabled.map { _ in () }.eraseToAnyPublisher(),
            engine.$visualizerChoice.map { _ in () }.eraseToAnyPublisher(),
            engine.$isPlaying.map { _ in () }.eraseToAnyPublisher(),
            engine.$currentIndex.map { _ in () }.eraseToAnyPublisher(),
            engine.$queue.map { _ in () }.eraseToAnyPublisher()
        ]
        Publishers.MergeMany(changes).dropFirst(changes.count)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refreshBindings() }
            .store(in: &bag)

        // Time moves on its own: positions and durations, and the script's position-change event.
        Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.tick() }
            .store(in: &bag)
    }

    private var hasControlsHandler: Bool {
        runtime.scenes.contains { scene in
            scene.allNodes.contains { $0.tag == "controls" && $0.events["currentposition_onchange"] != nil }
        }
    }

    private var lastPosition = -1.0

    private func tick() {
        refreshBindings()
        guard let engine, abs(engine.currentTime - lastPosition) >= 0.2 else { return }
        lastPosition = engine.currentTime
        fireAll(tag: "controls", event: "currentposition_onchange")
    }

    // MARK: Live bindings
    //
    // Layouts tie element properties to the player with "wmpprop:player.settings.volume" (a value to
    // follow) and "wmpenabled:player.controls.play" (switched on while the player can do that).
    // This keeps those properties in step. It works with or without a script, and it doesn't call
    // the skin's change handlers (only the user's own changes do), so a script can't be set
    // off by the player changing under it.

    private struct LiveBinding {
        let id: String
        let key: String
        let path: [String]
        let enabledKind: Bool
    }
    private var bindings: [LiveBinding] = []
    private var lastValues: [String: String] = [:]

    private func collectBindings() {
        bindings = []
        lastValues = [:]
        for scene in runtime.scenes {
            for node in scene.allNodes {
                for (key, raw) in node.props {
                    let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
                    if text.hasPrefix("wmpprop:") {
                        let path = text.dropFirst("wmpprop:".count).split(separator: ".").map(String.init)
                        bindings.append(LiveBinding(id: node.id, key: key, path: path, enabledKind: false))
                    } else if text.hasPrefix("wmpenabled:"), key == "enabled" {
                        let path = text.dropFirst("wmpenabled:".count).split(separator: ".").map(String.init)
                        bindings.append(LiveBinding(id: node.id, key: key, path: path, enabledKind: true))
                    }
                }
            }
        }
    }

    private func refreshBindings() {
        for binding in bindings {
            let value: Any?
            if binding.enabledKind {
                guard binding.path.count == 3, binding.path[0] == "player", binding.path[1] == "controls" else { continue }
                value = isAvailable(binding.path[2])
            } else if let (domain, key) = Self.resolve(binding.path) {
                value = get(domain, key)
            } else { continue }
            guard let value else { continue }

            let text = Self.string(from: value)
            let slot = binding.id + "." + binding.key
            if lastValues[slot] == text { continue }
            lastValues[slot] = text

            if binding.enabledKind {
                runtime.set(binding.id, enabled: (value as? Bool) ?? true)
            } else if binding.key == "visible" {
                runtime.set(binding.id, visible: (value as? Bool) ?? true)
            } else {
                runtime.setProp(binding.id, binding.key, text)
            }
        }
    }

    /// "player.settings.volume" -> ("settings", "volume"), and so on.
    private static func resolve(_ path: [String]) -> (String, String)? {
        let children = ["controls": "controls", "settings": "settings",
                        "currentmedia": "media", "currentplaylist": "playlist"]
        switch path.first {
        case "player":
            if path.count == 3, let domain = children[path[1]] { return (domain, path[2]) }
            if path.count == 2 { return ("player", path[1]) }
            return nil
        case "eq", "mediacenter":
            return path.count == 2 ? (path[0], path[1]) : nil
        default:
            return nil
        }
    }

    private static func string(from value: Any) -> String {
        if let boxed = value as? NSNumber {
            if CFGetTypeID(boxed) == CFBooleanGetTypeID() { return boxed.boolValue ? "true" : "false" }
            return format(boxed.doubleValue)
        }
        if let flag = value as? Bool { return flag ? "true" : "false" }
        if let number = value as? Double { return format(number) }
        if let number = value as? Int { return String(number) }
        return "\(value)"
    }

    /// Whether the player can do something right now (player.controls.isAvailable / wmpenabled:).
    private func isAvailable(_ name: String) -> Bool {
        guard let engine else { return false }
        switch name {
        case "play": return engine.isEnabled(.play)
        case "pause": return engine.isEnabled(.pause)
        case "stop": return engine.isEnabled(.stop)
        case "next": return engine.isEnabled(.next)
        case "previous": return engine.isEnabled(.previous)
        case "fastforward": return engine.isEnabled(.skipForward)
        case "fastreverse": return engine.isEnabled(.skipBack)
        case "currentposition", "currentpositionstring", "step": return engine.currentTrack != nil
        default: return true
        }
    }

    private func mediaChanged() {
        fireAll(tag: "player", event: "openstate_onchange")
        let active = engine?.currentTrack?.hasVideo == true
        if active != videoActive {
            videoActive = active
            fireAll(tag: "video", event: active ? "onvideostart" : "onvideoend")
        }
    }

    // MARK: The object model (what scripts can read, write and call)

    func get(_ domain: String, _ key: String) -> Any? {
        guard let engine else { return nil }
        switch domain {
        case "player":
            switch key {
            case "openstate": return engine.currentTrack != nil ? 13 : 0          // osMediaOpen / osUndefined
            case "playstate":
                if engine.isPlaying { return 3 }                                     // psPlaying
                return engine.currentTrack != nil && engine.currentTime > 0 ? 2 : 1  // psPaused / psStopped
            case "url": return engine.currentTrack?.url.absoluteString ?? ""
            case "status":
                if engine.isPlaying { return "Playing" }
                return engine.currentTrack != nil ? "Paused" : "Ready"
            case "version": return "12.0.0"
            case "isonline": return true
            case "fullscreen": return false
            default: return nil
            }
        case "playlist":
            switch key {
            case "count": return engine.queue.count
            case "name": return "Now Playing"
            default: return nil
            }
        case "mediacenter":
            switch key {
            case "effecttype":
                switch VisualizerStyle(rawValue: engine.visualizerChoice) {
                case .bars: return "Bars"
                case .waveform: return "Waveform"
                case .radial: return "Radial"
                case nil: return ""
                }
            case "effectpreset": return 0
            default: return nil
            }
        case "controls":
            switch key {
            case "currentposition": return engine.currentTime
            case "currentpositionstring": return formatTime(engine.currentTime)
            default: return nil
            }
        case "media":
            let track = engine.currentTrack
            switch key {
            case "name", "title": return track?.title ?? ""
            case "sourceurl": return track?.url.absoluteString ?? ""
            case "author", "artist": return track?.artist ?? ""
            case "duration": return engine.duration
            case "durationstring": return formatTime(engine.duration)
            case "imagesourcewidth": return track?.hasVideo == true ? 640 : 0
            case "imagesourceheight": return track?.hasVideo == true ? 360 : 0
            default: return nil
            }
        case "settings":
            switch key {
            case "volume": return Double(engine.volume) * 100
            case "balance": return Double(engine.balance) * 100
            case "mute": return engine.volume == 0
            case "rate": return 1.0
            case "autostart": return true
            default: return nil
            }
        case "eq":
            if key == "enabled" { return engine.eqEnabled }
            if key == "bypass" { return !engine.eqEnabled }
            if key.hasPrefix("gainlevel"), let band = Int(key.dropFirst("gainlevel".count)), (1...10).contains(band) {
                return Double(engine.eqGains[band - 1])
            }
            return nil
        default:
            if domain.hasPrefix("el:") { return elementGet(String(domain.dropFirst(3)), key) }
            return nil
        }
    }

    func set(_ domain: String, _ key: String, _ value: Any?) {
        guard let engine else { return }
        let number = (value as? NSNumber)?.doubleValue ?? Double("\(value ?? "")") ?? 0
        switch domain {
        case "controls":
            if key == "currentposition" { engine.seek(to: number) }
        case "settings":
            if key == "volume" { engine.volume = Float(min(max(number / 100, 0), 1)) }
            if key == "balance" { engine.balance = Float(min(max(number / 100, -1), 1)) }
            if key == "mute" {
                let on = (value as? NSNumber)?.boolValue ?? false
                if on, engine.volume > 0 { volumeBeforeMute = engine.volume; engine.volume = 0 }
                if !on, engine.volume == 0 { engine.volume = volumeBeforeMute }
            }
        case "mediacenter":
            if key == "effecttype" {
                switch "\(value ?? "")".lowercased() {
                case "bars": engine.visualizerChoice = VisualizerStyle.bars.rawValue
                case "waveform": engine.visualizerChoice = VisualizerStyle.waveform.rawValue
                case "radial": engine.visualizerChoice = VisualizerStyle.radial.rawValue
                default: engine.visualizerChoice = "off"
                }
            }
        case "view":
            if key == "timerinterval" { startViewTimers(override: number) }
        case "eq":
            if key == "enabled" { engine.eqEnabled = (value as? NSNumber)?.boolValue ?? true }
            if key == "bypass" { engine.eqEnabled = !((value as? NSNumber)?.boolValue ?? false) }
            if key.hasPrefix("gainlevel"), let band = Int(key.dropFirst("gainlevel".count)), (1...10).contains(band) {
                engine.setEQGain(Float(min(max(number, -Double(EQ.range)), Double(EQ.range))), band: band - 1)
            }
        default:
            if domain.hasPrefix("el:") { elementSet(String(domain.dropFirst(3)), key, value) }
        }
    }

    func call(_ domain: String, _ name: String, _ args: [Any]) -> Any? {
        guard let engine else { return nil }
        switch domain {
        case "controls":
            switch name {
            case "play": engine.trigger(.play)
            case "pause": engine.trigger(.pause)
            case "stop": engine.trigger(.stop)
            case "next": engine.trigger(.next)
            case "previous": engine.trigger(.previous)
            case "fastforward": engine.trigger(.skipForward)
            case "fastreverse": engine.trigger(.skipBack)
            case "isavailable": return isAvailable("\(args.first ?? "")".lowercased())
            default: break
            }
        case "media":
            if name == "getiteminfo" || name == "getiteminfobyatom" {
                let key = "\(args.first ?? "")".lowercased()
                let track = engine.currentTrack
                if key.contains("author") || key.contains("artist") { return track?.artist ?? "" }
                if key.contains("title") || key.contains("name") { return track?.title ?? "" }
                return ""
            }
        case "eq":
            if name == "reset" { engine.resetEQ() }
        case "player":
            if name == "launchurl" { openLink("\(args.first ?? "")") }
        case "view":
            if name == "close" { NSApp.keyWindow?.performClose(nil) }
            if name == "minimize" { NSApp.keyWindow?.miniaturize(nil) }
        case "theme":
            if name == "openview" || name == "loadview" || name == "changeview" {
                runtime.showView("\(args.first ?? "")")
            }
            if name == "opendialog" {
                appState?.showingImporter = true     // the file picker is asynchronous; no path to return
                return ""
            }
        default:
            if domain.hasPrefix("el:") { return elementCall(String(domain.dropFirst(3)), name, args) }
        }
        return nil
    }

    /// Only web links, and only in answer to a click.
    private func openLink(_ text: String) {
        guard inUserEvent, let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        else { runtime.log("Blocked launchURL(\(text))"); return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Elements

    private func elementGet(_ id: String, _ key: String) -> Any? {
        guard let node = runtime.node(named: id) else { return nil }
        switch key {
        case "visible": return runtime.isVisible(node)
        case "enabled": return elementEnabled(node)
        case "zindex": return runtime.zIndex(node)
        case "left": return runtime.left(node)
        case "top": return runtime.top(node)
        case "width": return node.width ?? runtime.specs(ownedBy: node.id).first?.width ?? 0
        case "height": return node.height ?? runtime.specs(ownedBy: node.id).first?.height ?? 0
        case "id": return node.name ?? node.id
        case "textwidth":
            let size = runtime.specs(ownedBy: node.id).first?.fontSize ?? 10
            let text = runtime.text(for: node.id) ?? node.props["value"] ?? ""
            return (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: CGFloat(size))]).width
        default:
            guard let value = runtime.prop(node.id, key) else { return nil }
            if let number = Double(value) { return number }
            if value.lowercased() == "true" { return true }
            if value.lowercased() == "false" { return false }
            return value
        }
    }

    /// A button reflects the player (play is off with nothing queued, and so on) unless the script says otherwise.
    private func elementEnabled(_ node: SceneNode) -> Bool {
        if let override = runtime.enabledOverride(node.id) { return override }
        if let spec = runtime.specs(ownedBy: node.id).first(where: { $0.kind == .imageButton }),
           spec.binding != .scriptOnly, let engine {
            return node.enabled && engine.isEnabled(spec.binding)
        }
        return node.enabled
    }

    private func elementSet(_ id: String, _ key: String, _ value: Any?) {
        let flag = (value as? NSNumber)?.boolValue ?? false
        let number = (value as? NSNumber)?.doubleValue ?? Double("\(value ?? "")")
        switch key {
        case "visible": runtime.set(id, visible: flag)
        case "enabled": runtime.set(id, enabled: flag)
        case "zindex": if let number { runtime.set(id, zIndex: Int(number)) }
        case "left": if let number { moves[id] = nil; runtime.set(id, left: number) }
        case "top": if let number { moves[id] = nil; runtime.set(id, top: number) }
        default:
            if value == nil || value is NSNull {
                runtime.setProp(id, key, "")
            } else if let boxed = value as? NSNumber {
                // A JavaScript true/false arrives as a boolean NSNumber; keep it distinct from 1/0.
                let isBool = CFGetTypeID(boxed) == CFBooleanGetTypeID()
                runtime.setProp(id, key, isBool ? (boxed.boolValue ? "true" : "false") : Self.format(boxed.doubleValue))
            } else {
                runtime.setProp(id, key, "\(value ?? "")")
            }
        }
    }

    private func elementCall(_ id: String, _ name: String, _ args: [Any]) -> Any? {
        switch name {
        case "moveto":
            // moveTo(x, y [, duration [, easing]]): slides there (a quarter second by default; a
            // duration of 0 jumps) and then runs the element's onendmove.
            let x = (args.first as? NSNumber)?.doubleValue
            let y = (args.count > 1 ? args[1] as? NSNumber : nil)?.doubleValue
            var seconds = 0.25
            if args.count > 2, let raw = (args[2] as? NSNumber)?.doubleValue {
                seconds = raw > 10 ? raw / 1000 : raw      // small numbers are seconds, large are milliseconds
            }
            let easing = args.count > 3 ? "\(args[3])" : "easeInOut"
            beginMove(id, x: x, y: y, duration: min(max(seconds, 0), 5), easing: easing)
        case "next": engine?.trigger(.nextVisualization)
        case "previous": engine?.trigger(.previousVisualization)
        default: break   // setColumnResizeMode, setColumnWidth, ... have nothing to do yet
        }
        return nil
    }

    // MARK: Helpers

    nonisolated static func format(_ number: Double) -> String {
        number == number.rounded() && abs(number) < 1e9 ? String(Int(number)) : String(number)
    }

    private static func isIdentifier(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z_$][A-Za-z0-9_$]*$"#, options: .regularExpression) != nil
            && !reserved.contains(name)
    }

    private static let reserved: Set<String> = [
        "player", "eq", "view", "theme", "mediacenter", "this", "var", "function", "new", "delete", "in", "of",
        "undefined", "null", "true", "false", "NaN", "Infinity", "window", "document"
    ]

    // MARK: Installing the sandbox

    /// Defines the bridge functions and the WMP-style globals. Made outside the main actor on purpose
    /// (the blocks are called by JavaScriptCore); they hop back through `onMainActor`.
    private nonisolated static func install(on context: JSContext, host: ScriptHost) {
        let getBlock: @convention(block) (String, String) -> Any? = { domain, key in
            onMainActor { host.get(domain, key) }
        }
        let setBlock: @convention(block) (String, String, Any?) -> Void = { domain, key, value in
            onMainActor { host.set(domain, key, value) }
        }
        let callBlock: @convention(block) (String, String, [Any]) -> Any? = { domain, name, args in
            onMainActor { host.call(domain, name, args) }
        }
        let timerBlock: @convention(block) (Double, Bool) -> Int = { ms, repeats in
            onMainActor { host.addTimer(ms: ms, repeats: repeats) }
        }
        let clearBlock: @convention(block) (Int) -> Void = { id in
            onMainActor { host.clearTimer(id) }
        }
        context.setObject(timerBlock, forKeyedSubscript: "__timer" as NSString)
        context.setObject(clearBlock, forKeyedSubscript: "__clear" as NSString)
        context.setObject(getBlock, forKeyedSubscript: "__get" as NSString)
        context.setObject(setBlock, forKeyedSubscript: "__set" as NSString)
        context.setObject(callBlock, forKeyedSubscript: "__call" as NSString)
        context.evaluateScript(bootstrap)
    }

    private nonisolated static let bootstrap = #"""
    (function (g) {
      var constants = {
        osUndefined: 0, osPlaylistChanging: 1, osPlaylistLocating: 2, osPlaylistConnecting: 3,
        osPlaylistLoading: 4, osPlaylistOpening: 5, osPlaylistOpenNoMedia: 6, osPlaylistChanged: 7,
        osMediaChanging: 8, osMediaLocating: 9, osMediaConnecting: 10, osMediaLoading: 11,
        osMediaOpening: 12, osMediaOpen: 13, osBeginCodecAcquisition: 14, osEndCodecAcquisition: 15,
        psUndefined: 0, psStopped: 1, psPaused: 2, psPlaying: 3, psScanForward: 4, psScanReverse: 5,
        psBuffering: 6, psWaiting: 7, psMediaEnded: 8, psTransitioning: 9, psReady: 10, psReconnecting: 11
      };
      for (var name in constants) { g[name] = constants[name]; }

      var methods = {
        player: { launchurl: 1, close: 1 },
        controls: { play: 1, pause: 1, stop: 1, next: 1, previous: 1, fastforward: 1, fastreverse: 1, playitem: 1, isavailable: 1 },
        playlist: {},
        mediacenter: {},
        media: { getiteminfo: 1, getiteminfobyatom: 1 },
        settings: {},
        eq: { reset: 1 },
        view: { close: 1, minimize: 1, maximize: 1, restore: 1, setfocus: 1 },
        theme: { openview: 1, loadview: 1, changeview: 1, opendialog: 1, savepreference: 1, loadpreference: 1 },
        el: { moveto: 1, next: 1, previous: 1, setcolumnresizemode: 1, setcolumnwidth: 1, reset: 1, setfocus: 1 }
      };

      // Names are case-insensitive, like in WMP.
      function domain(name, kind, children) {
        var table = methods[kind] || {};
        return new Proxy({}, {
          get: function (target, prop) {
            if (typeof prop !== 'string') { return undefined; }
            var key = prop.toLowerCase();
            if (children && children[key]) { return children[key]; }
            if (table[key]) { return function () { return __call(name, key, Array.prototype.slice.call(arguments)); }; }
            return __get(name, key);
          },
          set: function (target, prop, value) { __set(name, String(prop).toLowerCase(), value); return true; }
        });
      }

      var media = domain('media', 'media');
      g.player = domain('player', 'player', {
        controls: domain('controls', 'controls', { currentitem: media }),
        settings: domain('settings', 'settings'),
        currentmedia: media,
        currentplaylist: domain('playlist', 'playlist')
      });
      g.mediacenter = domain('mediacenter', 'mediacenter');
      g.eq = domain('eq', 'eq');
      g.view = domain('view', 'view');
      g.theme = domain('theme', 'theme');
      g.__element = function (id) { return domain('el:' + id, 'el'); };

      // Timers: the host runs the clock and calls __fire when one is due.
      var callbacks = {};
      function schedule(fn, ms, repeats) {
        var id = __timer(Number(ms) || 0, repeats);
        if (!id) { return 0; }
        callbacks[id] = { fn: fn, repeats: repeats };
        return id;
      }
      g.setTimeout = function (fn, ms) { return schedule(fn, ms, false); };
      g.setInterval = function (fn, ms) { return schedule(fn, ms, true); };
      g.clearTimeout = g.clearInterval = function (id) { delete callbacks[id]; __clear(id); };
      g.__fire = function (id) {
        var entry = callbacks[id];
        if (!entry) { return; }
        if (!entry.repeats) { delete callbacks[id]; }
        if (typeof entry.fn === 'function') { entry.fn(); } else { (0, eval)(String(entry.fn)); }
      };
    })(this);
    """#
}
