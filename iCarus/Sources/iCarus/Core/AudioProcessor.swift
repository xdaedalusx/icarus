import Foundation
import AVFoundation
import MediaToolbox

// MARK: - EQ presets

struct EQPreset: Equatable {
    let name: String
    /// Gain in dB for 31, 62, 125, 250, 500, 1k, 2k, 4k, 8k, 16k Hz.
    let gains: [Float]

    static let all: [EQPreset] = [
        EQPreset(name: "Flat",         gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        EQPreset(name: "Rock",         gains: [5, 4, 3, 1, -1, -1, 1, 3, 4, 5]),
        EQPreset(name: "Pop",          gains: [-1, 2, 4, 5, 3, 0, -1, -1, -1, -1]),
        EQPreset(name: "Bass Boost",   gains: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        EQPreset(name: "Treble Boost", gains: [0, 0, 0, 0, 0, 0, 2, 4, 5, 6]),
        EQPreset(name: "Vocal",        gains: [-2, -2, -1, 1, 4, 4, 3, 1, 0, -1]),
        EQPreset(name: "Classical",    gains: [0, 0, 0, 0, 0, 0, -2, -2, -2, -4]),
        EQPreset(name: "Electronic",   gains: [5, 4, 1, 0, -2, 2, 1, 1, 4, 5])
    ]
    static let flat = all[0]
}

// MARK: - Real-time audio processor
//
// Attached to each AVPlayerItem as an MTAudioProcessingTap. In one pass it:
//   1. applies a 10-band peaking EQ,
//   2. applies left/right balance,
//   3. copies samples into a ring buffer (and RMS levels) for the visualizer.
//
// The audio thread must never block or allocate, so settings are shared via
// plain memory. A torn read is at worst one slightly-off audio buffer, which
// is inaudible, so no locks are used.

final class AudioProcessor: @unchecked Sendable {
    static let bandFrequencies: [Float] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let bandCount = 10
    private static let maxChannels = 8
    private static let ringSize = 8192          // power of two

    // Written by the main thread, read by the audio thread.
    private let targetGains: UnsafeMutablePointer<Float>    // dB per band
    private let params: UnsafeMutablePointer<Float>         // [0] EQ on, [1] left gain, [2] right gain
    private let version: UnsafeMutablePointer<Int>          // bumped whenever settings change

    // Audio thread only.
    private let coefficients: UnsafeMutablePointer<Float>   // 5 per band: b0 b1 b2 a1 a2
    private let activeBands: UnsafeMutablePointer<Bool>
    private let filterState: UnsafeMutablePointer<Float>    // 2 per band per channel
    private var appliedVersion = -1
    private var eqActive = false
    private var headroom: Float = 1

    // Written by the audio thread, read by the main thread.
    private let ring: UnsafeMutablePointer<Float>
    private let writePosition: UnsafeMutablePointer<Int>
    private let rms: UnsafeMutablePointer<Float>            // [0] left, [1] right

    // Stream format (set in prepare, before processing starts).
    private(set) var sampleRate: Double = 44100
    private var channels = 2
    private var isFloat32 = false
    private var interleaved = false

    var rmsLeft: Float { rms[0] }
    var rmsRight: Float { rms[1] }

    init() {
        let bands = AudioProcessor.bandCount
        targetGains = .allocate(capacity: bands)
        targetGains.initialize(repeating: 0, count: bands)
        params = .allocate(capacity: 3)
        params.initialize(repeating: 1, count: 3)
        params[0] = 1
        version = .allocate(capacity: 1)
        version.initialize(to: 0)
        coefficients = .allocate(capacity: bands * 5)
        coefficients.initialize(repeating: 0, count: bands * 5)
        activeBands = .allocate(capacity: bands)
        activeBands.initialize(repeating: false, count: bands)
        filterState = .allocate(capacity: AudioProcessor.maxChannels * bands * 2)
        filterState.initialize(repeating: 0, count: AudioProcessor.maxChannels * bands * 2)
        ring = .allocate(capacity: AudioProcessor.ringSize)
        ring.initialize(repeating: 0, count: AudioProcessor.ringSize)
        writePosition = .allocate(capacity: 1)
        writePosition.initialize(to: 0)
        rms = .allocate(capacity: 2)
        rms.initialize(repeating: 0, count: 2)
    }

    deinit {
        targetGains.deallocate(); params.deallocate(); version.deallocate()
        coefficients.deallocate(); activeBands.deallocate(); filterState.deallocate()
        ring.deallocate(); writePosition.deallocate(); rms.deallocate()
    }

    // MARK: Main-thread API

    /// `gains` are dB per band (already including any bass/treble offsets).
    func update(gains: [Float], enabled: Bool, balance: Float) {
        for i in 0..<Self.bandCount { targetGains[i] = i < gains.count ? gains[i] : 0 }
        params[0] = enabled ? 1 : 0
        params[1] = balance > 0 ? 1 - balance : 1
        params[2] = balance < 0 ? 1 + balance : 1
        version.pointee &+= 1
    }

    /// Copies the most recent `count` mono samples (oldest first).
    func copyRecent(_ destination: UnsafeMutablePointer<Float>, count: Int) {
        let mask = Self.ringSize - 1
        let end = writePosition.pointee
        for i in 0..<count { destination[i] = ring[(end - count + i) & mask] }
    }

    /// Creates a tap bound to this processor. The processor must outlive it.
    func makeTap() -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passUnretained(self).toOpaque(),
            init: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: tapUnprepare,
            process: tapProcess
        )
        var tap: Unmanaged<MTAudioProcessingTap>?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr else { return nil }
        return tap?.takeRetainedValue()
    }

    // MARK: Tap callbacks

    fileprivate func prepare(_ format: AudioStreamBasicDescription) {
        sampleRate = format.mSampleRate
        channels = min(Int(format.mChannelsPerFrame), Self.maxChannels)
        isFloat32 = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0 && format.mBitsPerChannel == 32
        interleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        filterState.initialize(repeating: 0, count: Self.maxChannels * Self.bandCount * 2)
        appliedVersion = -1
    }

    fileprivate func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        guard isFloat32, frames > 0 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard buffers.count > 0 else { return }

        if appliedVersion != version.pointee {
            rebuildCoefficients()
            appliedVersion = version.pointee
        }

        let channelCount = interleaved
            ? min(Int(buffers[0].mNumberChannels), Self.maxChannels)
            : min(buffers.count, Self.maxChannels)
        let stride = interleaved ? channelCount : 1

        var left: UnsafeMutablePointer<Float>?
        var right: UnsafeMutablePointer<Float>?

        for ch in 0..<channelCount {
            guard let raw = interleaved ? buffers[0].mData : buffers[ch].mData else { continue }
            let base = raw.assumingMemoryBound(to: Float.self) + (interleaved ? ch : 0)

            if eqActive {
                for band in 0..<Self.bandCount where activeBands[band] {
                    let c = coefficients + band * 5
                    let b0 = c[0], b1 = c[1], b2 = c[2], a1 = c[3], a2 = c[4]
                    let state = filterState + (ch * Self.bandCount + band) * 2
                    var z1 = state[0], z2 = state[1]
                    for i in 0..<frames {
                        let x = base[i * stride]
                        let y = b0 * x + z1
                        z1 = b1 * x - a1 * y + z2
                        z2 = b2 * x - a2 * y
                        base[i * stride] = y
                    }
                    state[0] = z1
                    state[1] = z2
                }
            }

            var gain: Float = ch < 2 ? params[1 + ch] : 1
            if eqActive { gain *= headroom }
            if gain != 1 {
                for i in 0..<frames { base[i * stride] *= gain }
            }

            if ch == 0 { left = base }
            if ch == 1 { right = base }
        }

        // Feed the visualizer (post-EQ, so it shows what you hear).
        guard let left else { return }
        let mask = Self.ringSize - 1
        var position = writePosition.pointee
        var sumL: Float = 0, sumR: Float = 0
        for i in 0..<frames {
            let l = left[i * stride]
            let r = right?[i * stride] ?? l
            sumL += l * l
            sumR += r * r
            ring[position & mask] = (l + r) * 0.5
            position &+= 1
        }
        writePosition.pointee = position
        rms[0] = sqrtf(sumL / Float(frames))
        rms[1] = sqrtf(sumR / Float(frames))
    }

    /// RBJ peaking-EQ biquads, normalised by a0.
    private func rebuildCoefficients() {
        let fs = Float(sampleRate)
        var anyActive = false
        var maxGain: Float = 0

        for band in 0..<Self.bandCount {
            let gain = targetGains[band]
            let frequency = Self.bandFrequencies[band]
            if abs(gain) < 0.05 || frequency >= fs * 0.45 {
                activeBands[band] = false
                continue
            }
            activeBands[band] = true
            anyActive = true
            maxGain = max(maxGain, gain)

            let a = powf(10, gain / 40)
            let w0 = 2 * Float.pi * frequency / fs
            let alpha = sinf(w0) / (2 * 1.4)
            let a0 = 1 + alpha / a
            let c = coefficients + band * 5
            c[0] = (1 + alpha * a) / a0
            c[1] = (-2 * cosf(w0)) / a0
            c[2] = (1 - alpha * a) / a0
            c[3] = (-2 * cosf(w0)) / a0
            c[4] = (1 - alpha / a) / a0
        }

        eqActive = params[0] > 0.5 && anyActive
        // Back off by half the biggest boost so loud settings don't clip.
        headroom = powf(10, -(maxGain * 0.5) / 20)
    }
}

// MARK: - C callbacks (must not capture context; the processor arrives via tap storage)

private let tapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, tapStorageOut in
    tapStorageOut.pointee = clientInfo
}

private let tapFinalize: MTAudioProcessingTapFinalizeCallback = { _ in }

private let tapUnprepare: MTAudioProcessingTapUnprepareCallback = { _ in }

private let tapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, format in
    let processor = Unmanaged<AudioProcessor>
        .fromOpaque(MTAudioProcessingTapGetStorage(tap))
        .takeUnretainedValue()
    processor.prepare(format.pointee)
}

private let tapProcess: MTAudioProcessingTapProcessCallback = { tap, frames, _, bufferList, framesOut, flagsOut in
    let status = MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut)
    guard status == noErr else { return }
    let processor = Unmanaged<AudioProcessor>
        .fromOpaque(MTAudioProcessingTapGetStorage(tap))
        .takeUnretainedValue()
    processor.process(bufferList, frames: framesOut.pointee)
}
