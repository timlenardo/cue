import Foundation
import AVFoundation
import Combine

/// Thin wrapper around AVPlayer for the live podcast case.
/// Exposes time + playing as @Published so SwiftUI can react.
@MainActor
final class AudioPlayer: ObservableObject {
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isPlaying: Bool = false

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?

    func load(url: URL) {
        cleanup()
        configureAudioSession()

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player

        // Observe duration once readyToPlay flips.
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .readyToPlay else { return }
            let seconds = CMTimeGetSeconds(item.duration)
            guard seconds.isFinite else { return }
            Task { @MainActor [weak self] in
                self?.duration = seconds
            }
        }

        // Time updates ~10Hz — fine for UI. queue: .main means the closure runs
        // on the main thread; assumeIsolated lets us mutate @Published safely.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let seconds = CMTimeGetSeconds(time)
            guard seconds.isFinite else { return }
            MainActor.assumeIsolated {
                self?.currentTime = seconds
            }
        }
    }

    func play() {
        player?.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func setRate(_ rate: Float) {
        player?.rate = isPlaying ? rate : 0
    }

    func seek(to seconds: TimeInterval) {
        let t = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player?.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
    }

    func unload() {
        cleanup()
        currentTime = 0
        duration = 0
        isPlaying = false
    }

    private func cleanup() {
        statusObservation?.invalidate()
        statusObservation = nil
        if let observer = timeObserver, let player {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil
        player?.pause()
        player = nil
    }

    private func configureAudioSession() {
        // .playAndRecord (vs .playback) so MicCapture can run an input tap
        // simultaneously with podcast playback for the always-on wake-word
        // listener. .defaultToSpeaker keeps the loudspeaker as output when
        // no headphones are connected. .allowBluetooth opts in to the HFP
        // Bluetooth profile (mono, lower quality) so AirPods/headsets keep
        // working; .allowBluetoothA2DP keeps A2DP (high-quality stereo) on
        // for output where possible. iOS will pick HFP automatically when
        // the mic is active.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .allowAirPlay]
        )
        try? session.setActive(true)
    }
}
