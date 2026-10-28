import Foundation
import AVFoundation
import Combine

/// Shows the picture for files that contain video.
///
/// The sound still goes through PlayerEngine's audio path (so the EQ, balance and
/// visualizer all work on videos). This player is MUTED and only supplies the
/// picture. PlayerEngine is the clock: it tells this controller when to start,
/// pause and seek, and `correctDrift` nudges the picture back into sync if the
/// two ever wander apart.
@MainActor
final class VideoController: ObservableObject {
    let player = AVPlayer()

    /// True while the current track has video to show.
    @Published private(set) var isActive = false

    private var syncTask: Task<Void, Never>?
    private var isSeeking = false

    init() {
        player.isMuted = true
        player.actionAtItemEnd = .pause
    }

    func load(url: URL) {
        syncTask?.cancel()
        isSeeking = false
        player.pause()
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        isActive = true
    }

    func clear() {
        syncTask?.cancel()
        isSeeking = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        isActive = false
    }

    func pause() {
        syncTask?.cancel()
        isSeeking = false
        player.pause()
    }

    /// Jumps the picture to `seconds` and, if `playing`, starts it moving.
    func start(at seconds: Double, playing: Bool) {
        guard isActive else { return }
        syncTask?.cancel()
        isSeeking = true
        let target = CMTime(seconds: max(seconds, 0), preferredTimescale: 600)
        syncTask = Task { [weak self] in
            guard let self else { return }
            _ = await self.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            if Task.isCancelled { return }
            self.isSeeking = false
            if playing { self.player.play() }
        }
    }

    /// Called ~10 times a second while playing. Re-syncs if the picture is more
    /// than 0.2 s away from the audio.
    func correctDrift(to audioTime: Double) {
        guard isActive, !isSeeking, player.rate > 0 else { return }
        let drift = player.currentTime().seconds - audioTime
        guard drift.isFinite, abs(drift) > 0.2 else { return }
        // Aim slightly ahead to cover the time the seek itself takes.
        start(at: audioTime + 0.05, playing: true)
    }
}
