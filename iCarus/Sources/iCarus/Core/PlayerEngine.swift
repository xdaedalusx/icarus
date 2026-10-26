import Foundation
import AVFoundation
import Combine

/// All playback behaviour lives here. Skins never touch this class directly;
/// they only receive it through views, so functionality stays identical
/// no matter which skin is active.
@MainActor
final class PlayerEngine: ObservableObject {
    // MARK: Published state (read by skins/views)
    @Published private(set) var queue: [Track] = []
    @Published private(set) var currentIndex: Int?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var volume: Float = 0.8 {
        didSet { player.volume = volume }
    }
    @Published var shuffle = false
    @Published var repeatMode: RepeatMode = .off

    var currentTrack: Track? {
        guard let i = currentIndex, queue.indices.contains(i) else { return nil }
        return queue[i]
    }

    // MARK: Private
    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    init() {
        player.volume = volume

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let seconds = time.seconds
                if seconds.isFinite { self.currentTime = seconds }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleTrackEnded() }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
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
        currentIndex = index
        let item = AVPlayerItem(url: queue[index].url)
        player.replaceCurrentItem(with: item)
        currentTime = 0
        duration = 0
        player.play()
        isPlaying = true

        Task {
            if let d = try? await item.asset.load(.duration), d.seconds.isFinite {
                // Ignore if the user already moved on to another track.
                if player.currentItem === item { duration = d.seconds }
            }
        }
    }

    func togglePlayPause() {
        if currentTrack == nil {
            if !queue.isEmpty { play(index: 0) }
            return
        }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
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
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
    }

    // MARK: Private
    private func handleTrackEnded() {
        if repeatMode == .one, let i = currentIndex {
            play(index: i)
        } else {
            next()
        }
    }
}
