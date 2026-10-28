import Foundation

/// Turns raw samples from the AudioProcessor into things a skin can draw:
/// spectrum bars, a waveform, and left/right levels (all 0...1).
/// It's a separate ObservableObject so only visualizer widgets redraw ~30x/sec,
/// not the whole interface.
@MainActor
final class Visualizer: ObservableObject {
    static let bandCount = 32
    static let waveformCount = 128
    private static let windowSize = 2048

    @Published private(set) var bands = [Float](repeating: 0, count: Visualizer.bandCount)
    @Published private(set) var waveform = [Float](repeating: 0, count: Visualizer.waveformCount)
    @Published private(set) var levelLeft: Float = 0
    @Published private(set) var levelRight: Float = 0

    private let processor: AudioProcessor
    private let window: [Float]
    private var samples = [Float](repeating: 0, count: Visualizer.windowSize)
    private var coefficients = [Float](repeating: 0, count: Visualizer.bandCount)
    private var coefficientsRate: Float = 0
    private var timer: Timer?
    private var playing = false

    init(processor: AudioProcessor) {
        self.processor = processor
        let size = Visualizer.windowSize
        window = (0..<size).map { 0.5 - 0.5 * cosf(2 * Float.pi * Float($0) / Float(size - 1)) }
    }

    /// Runs the ~30 fps update only while audio is playing (and briefly after, to fade out).
    func setPlaying(_ value: Bool) {
        playing = value
        guard value, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    private func tick() {
        if playing {
            samples.withUnsafeMutableBufferPointer {
                processor.copyRecent($0.baseAddress!, count: Self.windowSize)
            }
            analyze()
        } else {
            fadeOut()
        }
    }

    // MARK: Analysis

    /// One Goertzel filter per log-spaced band. Cheap, and avoids needing an FFT.
    private func analyze() {
        let rate = Float(processor.sampleRate)
        if rate != coefficientsRate { rebuildCoefficients(rate: rate) }

        let size = Self.windowSize
        var newBands = bands
        for k in 0..<Self.bandCount {
            let coefficient = coefficients[k]
            var s1: Float = 0, s2: Float = 0
            for i in 0..<size {
                let s0 = samples[i] * window[i] + coefficient * s1 - s2
                s2 = s1
                s1 = s0
            }
            let power = s1 * s1 + s2 * s2 - coefficient * s1 * s2
            let amplitude = sqrtf(max(power, 0)) / (Float(size) * 0.25)
            var db = 20 * log10f(amplitude + 1e-7)
            db += Float(k) / Float(Self.bandCount - 1) * 12      // tilt: music rolls off toward the highs
            let level = min(max((db + 70) / 60, 0), 1)
            newBands[k] = max(level, bands[k] * 0.85)            // instant attack, smooth decay
        }
        bands = newBands

        let span = 512
        let step = span / Self.waveformCount
        let start = size - span
        waveform = (0..<Self.waveformCount).map { samples[start + $0 * step] }

        levelLeft = max(level(from: processor.rmsLeft), levelLeft * 0.85)
        levelRight = max(level(from: processor.rmsRight), levelRight * 0.85)
    }

    private func level(from rms: Float) -> Float {
        min(max((20 * log10f(rms + 1e-7) + 60) / 60, 0), 1)
    }

    private func fadeOut() {
        bands = bands.map { $0 * 0.8 }
        levelLeft *= 0.8
        levelRight *= 0.8
        waveform = [Float](repeating: 0, count: Self.waveformCount)
        if (bands.max() ?? 0) < 0.01, levelLeft < 0.01, levelRight < 0.01 {
            bands = [Float](repeating: 0, count: Self.bandCount)
            levelLeft = 0
            levelRight = 0
            timer?.invalidate()
            timer = nil
        }
    }

    private func rebuildCoefficients(rate: Float) {
        coefficientsRate = rate
        let low: Float = 40
        let high = min(16000, rate * 0.45)
        for k in 0..<Self.bandCount {
            let t = Float(k) / Float(Self.bandCount - 1)
            let frequency = low * powf(high / low, t)
            coefficients[k] = 2 * cosf(2 * Float.pi * frequency / rate)
        }
    }
}
