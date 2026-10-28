import Foundation
import AVFoundation
import Accelerate

/// One snapshot of the audio, ready to draw.
struct AudioFrame {
    /// Spectrum, low to high frequency, each 0...1.
    var bands: [Float]
    /// A short slice of the waveform, each -1...1.
    var waveform: [Float]
    /// Overall loudness 0...1 (RMS).
    var level: Float

    static let silent = AudioFrame(
        bands: [Float](repeating: 0, count: AudioAnalyzer.bandCount),
        waveform: [Float](repeating: 0, count: AudioAnalyzer.waveformCount),
        level: 0
    )
}

/// Turns the live audio buffers from the engine's tap into spectrum + waveform data.
///
/// Threading: `process` is called on an audio thread; `snapshot` is called from the
/// UI. A lock hands the finished frame across, so nothing here touches the main thread
/// and the UI can poll it as often as it likes (no SwiftUI publishing involved).
final class AudioAnalyzer: @unchecked Sendable {
    static let bandCount = 32
    static let waveformCount = 128

    // FFT working memory (only touched from the audio thread inside `process`)
    private let n = 1024
    private let log2n: vDSP_Length = 10
    private let fftSetup: FFTSetup
    private var window = [Float](repeating: 0, count: 1024)
    private var mono = [Float](repeating: 0, count: 1024)
    private var windowed = [Float](repeating: 0, count: 1024)
    private var realp = [Float](repeating: 0, count: 512)
    private var imagp = [Float](repeating: 0, count: 512)
    private var power = [Float](repeating: 0, count: 512)
    private var smoothed = [Float](repeating: 0, count: AudioAnalyzer.bandCount)
    private var edges: [(lo: Int, hi: Int, tilt: Float)] = []
    private var edgesRate: Double = 0

    // Shared with the UI
    private let lock = NSLock()
    private var latest = AudioFrame.silent
    private var lastUpdate: TimeInterval = 0

    init() {
        fftSetup = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))!
        vDSP_hann_window(&window, vDSP_Length(1024), Int32(vDSP_HANN_NORM))
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    /// A closure suitable for `PlayerEngine.setAudioTap`. Built here (not in a
    /// main-actor class) so it isn't tied to the main thread.
    func makeTapHandler() -> (AVAudioPCMBuffer, AVAudioTime) -> Void {
        return { [weak self] buffer, _ in self?.process(buffer) }
    }

    /// Latest frame. If audio stops arriving, fades smoothly to silence.
    func snapshot() -> AudioFrame {
        lock.lock()
        var frame = latest
        let updated = lastUpdate
        lock.unlock()

        let idle = ProcessInfo.processInfo.systemUptime - updated
        if idle > 0.12 {
            let fade = Float(1 - (idle - 0.12) * 3)
            if fade <= 0 { return .silent }
            frame.bands = frame.bands.map { $0 * fade }
            frame.waveform = frame.waveform.map { $0 * fade }
            frame.level *= fade
        }
        return frame
    }

    // MARK: Analysis (audio thread)

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames >= n else { return }
        let channelCount = Int(buffer.format.channelCount)
        let length = vDSP_Length(n)

        var rms: Float = 0
        mono.withUnsafeMutableBufferPointer { out in
            guard let p = out.baseAddress else { return }
            memcpy(p, channels[0], n * MemoryLayout<Float>.size)
            if channelCount > 1 {
                vDSP_vadd(p, 1, channels[1], 1, p, 1, length)
                var half: Float = 0.5
                vDSP_vsmul(p, 1, &half, p, 1, length)
            }
            vDSP_rmsqv(p, 1, &rms, length)
        }

        // Waveform: every 8th sample of the first 1024.
        var wave = [Float](repeating: 0, count: Self.waveformCount)
        for i in 0..<Self.waveformCount { wave[i] = mono[i * 8] }

        // Spectrum
        vDSP_vmul(mono, 1, window, 1, &windowed, 1, length)
        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                power.withUnsafeMutableBufferPointer { pp in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    windowed.withUnsafeBufferPointer { wp in
                        wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                        }
                    }
                    vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, pp.baseAddress!, 1, vDSP_Length(n / 2))
                }
            }
        }

        let rate = buffer.format.sampleRate
        if rate != edgesRate { rebuildEdges(sampleRate: rate) }

        var bands = [Float](repeating: 0, count: Self.bandCount)
        power.withUnsafeBufferPointer { pp in
            for (b, edge) in edges.enumerated() {
                var peak: Float = 0
                vDSP_maxv(pp.baseAddress! + edge.lo, 1, &peak, vDSP_Length(edge.hi - edge.lo + 1))
                let magnitude = peak.squareRoot() / Float(n)
                let db = 20 * log10(max(magnitude, 1e-7)) + edge.tilt
                let value = min(max((db + 80) / 70, 0), 1)
                // Instant attack, gentle fall.
                smoothed[b] = max(value, smoothed[b] * 0.85)
                bands[b] = smoothed[b]
            }
        }

        lock.lock()
        latest = AudioFrame(bands: bands, waveform: wave, level: min(rms * 3, 1))
        lastUpdate = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    /// Spreads the bands evenly on a log scale from 40 Hz to 16 kHz.
    private func rebuildEdges(sampleRate: Double) {
        let binHz = sampleRate / Double(n)
        let minHz = 40.0
        let maxHz = min(16000.0, sampleRate / 2 - binHz)
        var result: [(lo: Int, hi: Int, tilt: Float)] = []
        for b in 0..<Self.bandCount {
            let loHz = minHz * pow(maxHz / minHz, Double(b) / Double(Self.bandCount))
            let hiHz = minHz * pow(maxHz / minHz, Double(b + 1) / Double(Self.bandCount))
            let lo = max(1, Int(loHz / binHz))
            let hi = min(n / 2 - 1, max(lo, Int(hiHz / binHz)))
            // Music has far more energy in the lows; tilt +3 dB/octave so highs are visible.
            let tilt = Float(3 * log2(((loHz * hiHz).squareRoot()) / 100))
            result.append((lo, hi, tilt))
        }
        edges = result
        edgesRate = sampleRate
    }
}
