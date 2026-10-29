import Foundation
import AVFoundation
import Combine

// MARK: - File-scope helpers
//
// These live outside the @MainActor class on purpose: AVFoundation calls
// these closures from its own audio threads, so they must not be tied to
// the main thread.

private func scheduleAudio(on node: AVAudioPlayerNode,
                           file: AVAudioFile,
                           startFrame: AVAudioFramePosition,
                           frameCount: AVAudioFrameCount,
                           onFinished: @escaping @Sendable () -> Void) {
    node.scheduleSegment(file,
                         startingFrame: startFrame,
                         frameCount: frameCount,
                         at: nil,
                         completionCallbackType: .dataPlayedBack) { _ in onFinished() }
}

private func installMixerTap(on mixer: AVAudioMixerNode,
                             handler: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?) {
    mixer.removeTap(onBus: 0)
    guard let handler else { return }
    mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, time in
        handler(buffer, time)
    }
}

private enum PlaybackError: LocalizedError {
    case emptyFile
    var errorDescription: String? { "The file contains no audio." }
}

// MARK: - Engine

/// All playback behaviour lives here. Skins never touch this class directly;
/// they reach it only through views and the widget bindings, so functionality
/// stays identical no matter which skin is active.
///
/// Audio path:  player -> 10-band EQ -> balance mixer -> main mixer -> output
///
/// Future work this is designed to leave room for:
///  - Visualizations: call `setAudioTap(_:)` to receive the live audio buffers.
///  - Video pane: files that contain video will need an AVPlayer-based path
///    next to this audio path (AVAudioEngine can't render video).
@MainActor
final class PlayerEngine: ObservableObject {
    // MARK: Published state (read by skins/views)
    @Published private(set) var queue: [Track] = []
    @Published private(set) var currentIndex: Int?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var errorMessage: String?
    @Published var volume: Float = 0.8 {
        didSet { audioEngine.mainMixerNode.outputVolume = volume }
    }
    @Published var shuffle = false
    @Published var repeatMode: RepeatMode = .off

    /// Which visualizer an imported skin's visualizer window shows ("off" hides it).
    @Published var visualizerChoice = VisualizerStyle.bars.rawValue

    // Equalizer
    @Published private(set) var eqGains = [Float](repeating: 0, count: EQ.bandCount)
    @Published var eqEnabled = true {
        didSet { eqUnit.bypass = !eqEnabled; saveEQ() }
    }
    /// Stereo balance: -1 = all left, 0 = centre, 1 = all right.
    @Published var balance: Float = 0 {
        didSet { balanceMixer.pan = balance; saveEQ() }
    }

    var currentTrack: Track? {
        guard let i = currentIndex, queue.indices.contains(i) else { return nil }
        return queue[i]
    }

    // MARK: Private
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let eqUnit = AVAudioUnitEQ(numberOfBands: EQ.bandCount)
    private let balanceMixer = AVAudioMixerNode()
    /// Turns the audio tap into spectrum/waveform data for visualizers.
    let analyzer = AudioAnalyzer()
    /// Supplies the picture for files with video; the audio path stays the clock.
    let video = VideoController()
    private var visualizerClients = 0

    private var loadedFile: AVAudioFile?
    private var connectedFormat: AVAudioFormat?
    private var seekOffset = 0.0
    /// Bumped every time playback is (re)scheduled so stale "finished" callbacks are ignored.
    private var playToken = 0
    private var timerCancellable: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()

    init() {
        audioEngine.attach(playerNode)
        audioEngine.attach(eqUnit)
        audioEngine.attach(balanceMixer)
        audioEngine.connect(balanceMixer, to: audioEngine.mainMixerNode, format: nil)

        for (i, frequency) in EQ.frequencies.enumerated() {
            let band = eqUnit.bands[i]
            band.filterType = .parametric
            band.frequency = frequency
            band.bandwidth = 1.0
            band.gain = 0
            band.bypass = false
        }
        eqUnit.globalGain = 0

        // Property observers don't run inside init, so push saved values to the nodes by hand.
        let saved = EQSettings.load()
        eqGains = saved.gains
        eqEnabled = saved.enabled
        balance = saved.balance
        for (i, gain) in saved.gains.enumerated() { eqUnit.bands[i].gain = gain }
        eqUnit.bypass = !saved.enabled
        balanceMixer.pan = saved.balance
        audioEngine.mainMixerNode.outputVolume = volume

        // If the output device changes (headphones unplugged, etc.) the engine
        // stops itself; pick up again from the current position.
        NotificationCenter.default
            .publisher(for: .AVAudioEngineConfigurationChange, object: audioEngine)
            .sink { [weak self] _ in self?.handleConfigurationChange() }
            .store(in: &cancellables)
    }

    // MARK: Queue management

    /// Adds files to the queue, skipping any already in it.
    /// `autoplay` starts the first track only if the queue was empty.
    func add(urls: [URL], autoplay: Bool = true) {
        let fresh = urls.filter { url in !queue.contains { $0.url == url } }
        guard !fresh.isEmpty else { return }

        Task {
            var added: [Track] = []
            for url in fresh {
                let track = await Track.load(from: url)
                let duplicate = queue.contains { $0.url == url } || added.contains { $0.url == url }
                if !duplicate { added.append(track) }
            }
            let wasEmpty = queue.isEmpty
            queue.append(contentsOf: added)
            if autoplay, wasEmpty, !queue.isEmpty { play(index: 0) }
        }
    }

    /// Adds a file if needed and plays it right away.
    func addAndPlay(url: URL) {
        if let existing = queue.firstIndex(where: { $0.url == url }) {
            play(index: existing)
            return
        }
        Task {
            let track = await Track.load(from: url)
            if let existing = queue.firstIndex(where: { $0.url == url }) {
                play(index: existing)
            } else {
                queue.append(track)
                play(index: queue.count - 1)
            }
        }
    }

    func remove(at offsets: IndexSet) {
        let playingID = currentTrack?.id
        queue.remove(atOffsets: offsets)
        if let playingID, let newIndex = queue.firstIndex(where: { $0.id == playingID }) {
            currentIndex = newIndex
        } else {
            stop()
        }
    }

    func clearQueue() {
        queue.removeAll()
        stop()
    }

    // MARK: Transport

    func play(index: Int) {
        guard queue.indices.contains(index) else { return }
        let track = queue[index]
        do {
            let file = try AVAudioFile(forReading: track.url)
            loadedFile = file
            currentIndex = index
            duration = Double(file.length) / file.processingFormat.sampleRate
            errorMessage = nil
            try startPlayback(file: file, from: 0, autoplay: true)
            if track.hasVideo {
                video.load(url: track.url)
                video.start(at: 0, playing: true)
            } else {
                video.clear()
            }
        } catch {
            errorMessage = "Couldn't play “\(track.title)”: \(error.localizedDescription)"
            // Move on to the next track; the index only ever increases, so this can't loop.
            if index + 1 < queue.count {
                play(index: index + 1)
            } else {
                stop()
            }
        }
    }

    func togglePlayPause() {
        if currentTrack == nil {
            if !queue.isEmpty { play(index: 0) }
            return
        }
        if isPlaying {
            playerNode.pause()
            video.pause()
            isPlaying = false
            stopTimer()
        } else {
            do {
                if !audioEngine.isRunning { try audioEngine.start() }
                playerNode.play()
                isPlaying = true
                startTimer()
                if video.isActive { video.start(at: currentTime, playing: true) }
            } catch {
                errorMessage = "Couldn't resume playback: \(error.localizedDescription)"
            }
        }
    }

    func stop() {
        playToken &+= 1
        playerNode.stop()
        audioEngine.pause()
        stopTimer()
        loadedFile = nil
        video.clear()
        isPlaying = false
        currentIndex = nil
        currentTime = 0
        duration = 0
    }

    func next() {
        guard !queue.isEmpty else { return }
        if shuffle, queue.count > 1 {
            var candidate = Int.random(in: 0..<queue.count)
            while candidate == currentIndex { candidate = Int.random(in: 0..<queue.count) }
            play(index: candidate)
            return
        }
        let nextIndex = (currentIndex ?? -1) + 1
        if nextIndex < queue.count {
            play(index: nextIndex)
        } else if repeatMode == .all {
            play(index: 0)
        } else {
            stop()
        }
    }

    func previous() {
        guard !queue.isEmpty else { return }
        if currentTime > 3 {
            seek(to: 0)
        } else if let i = currentIndex, i > 0 {
            play(index: i - 1)
        } else {
            seek(to: 0)
        }
    }

    func seek(to seconds: Double) {
        guard let file = loadedFile else { return }
        let target = min(max(seconds, 0), max(duration - 0.05, 0))
        do {
            try startPlayback(file: file, from: target, autoplay: isPlaying)
            if video.isActive { video.start(at: target, playing: isPlaying) }
        } catch {
            errorMessage = "Couldn't seek: \(error.localizedDescription)"
        }
    }

    func clearError() { errorMessage = nil }

    // MARK: Equalizer

    func setEQGain(_ gain: Float, band: Int) {
        guard eqGains.indices.contains(band) else { return }
        let clamped = min(max(gain, -EQ.range), EQ.range)
        eqGains[band] = clamped
        eqUnit.bands[band].gain = clamped
        saveEQ()
    }

    func applyPreset(_ preset: EQPreset) {
        for (band, gain) in preset.gains.enumerated() where band < EQ.bandCount {
            eqGains[band] = gain
            eqUnit.bands[band].gain = gain
        }
        saveEQ()
    }

    /// Flattens every band and centres the balance.
    func resetEQ() {
        applyPreset(.flat)
        balance = 0
    }

    private func saveEQ() {
        EQSettings(enabled: eqEnabled, gains: eqGains, balance: balance).save()
    }

    // MARK: Audio tap (for future visualizations)

    /// Receives the live mixed audio. The handler is called on an audio thread,
    /// not the main thread. Pass nil to remove it.
    func setAudioTap(_ handler: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?) {
        installMixerTap(on: audioEngine.mainMixerNode, handler: handler)
    }

    /// Visualizer views call these as they appear/disappear. The tap (and the
    /// FFT work) only runs while at least one visualizer is on screen.
    func beginVisualization() {
        visualizerClients += 1
        if visualizerClients == 1 { setAudioTap(analyzer.makeTapHandler()) }
    }

    func endVisualization() {
        visualizerClients = max(0, visualizerClients - 1)
        if visualizerClients == 0 { setAudioTap(nil) }
    }

    // MARK: Playback internals

    private func startPlayback(file: AVAudioFile, from seconds: Double, autoplay: Bool) throws {
        playToken &+= 1
        let token = playToken
        playerNode.stop()

        // (Re)connect the chain only when the file's format differs from the last one.
        let format = file.processingFormat
        let sameFormat = connectedFormat.map {
            $0.sampleRate == format.sampleRate && $0.channelCount == format.channelCount
        } ?? false
        if !sameFormat {
            audioEngine.stop()
            audioEngine.connect(playerNode, to: eqUnit, format: format)
            audioEngine.connect(eqUnit, to: balanceMixer, format: format)
            connectedFormat = format
        }
        if !audioEngine.isRunning {
            audioEngine.prepare()
            try audioEngine.start()
        }

        let rate = format.sampleRate
        let startFrame = min(AVAudioFramePosition(seconds * rate), file.length)
        let frames = AVAudioFrameCount(max(file.length - startFrame, 0))
        guard frames > 0 else { throw PlaybackError.emptyFile }

        seekOffset = Double(startFrame) / rate
        currentTime = seekOffset

        scheduleAudio(on: playerNode, file: file, startFrame: startFrame, frameCount: frames) { [weak self] in
            Task { @MainActor in self?.segmentFinished(token: token) }
        }

        if autoplay {
            playerNode.play()
            isPlaying = true
            startTimer()
        } else {
            isPlaying = false
            stopTimer()
        }
    }

    private func segmentFinished(token: Int) {
        guard token == playToken else { return }   // stale callback from before a seek/skip
        handleTrackEnded()
    }

    private func handleTrackEnded() {
        if repeatMode == .one, let i = currentIndex {
            play(index: i)
        } else {
            next()
        }
    }

    private func handleConfigurationChange() {
        if visualizerClients > 0 { setAudioTap(analyzer.makeTapHandler()) }
        guard loadedFile != nil else { return }
        seek(to: currentTime)
    }

    private func startTimer() {
        timerCancellable = Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.updateTime() }
    }

    private func stopTimer() {
        timerCancellable = nil
    }

    private func updateTime() {
        guard isPlaying,
              let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else { return }
        let seconds = seekOffset + Double(playerTime.sampleTime) / playerTime.sampleRate
        if seconds.isFinite { currentTime = min(max(seconds, 0), duration) }
        video.correctDrift(to: currentTime)
    }
}
