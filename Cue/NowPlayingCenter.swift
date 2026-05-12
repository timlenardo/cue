import Foundation
import MediaPlayer
import UIKit

/// Glue between AppState/AudioPlayer and iOS's system-wide Now Playing
/// surface (lock screen, Control Center, headphone & CarPlay buttons).
///
/// Two responsibilities:
///   1. Receive remote commands and forward them to AppState.
///   2. Push current playback metadata + elapsed time into MPNowPlayingInfoCenter.
///
/// The class is a singleton because MPRemoteCommandCenter handlers must be
/// registered exactly once for the lifetime of the process; if we attach more
/// than once, the system delivers events to *every* attached target.
@MainActor
final class NowPlayingCenter {
    static let shared = NowPlayingCenter()

    private weak var state: AppState?
    private var didRegisterCommands = false

    func attach(_ state: AppState) {
        self.state = state
        if !didRegisterCommands {
            registerCommands()
            didRegisterCommands = true
        }
        UIApplication.shared.beginReceivingRemoteControlEvents()
    }

    // MARK: - Remote command handlers

    private func registerCommands() {
        let cc = MPRemoteCommandCenter.shared()

        cc.playCommand.addTarget { [weak self] _ in
            guard let s = self?.state else { return .noActionableNowPlayingItem }
            if s.live != nil, !s.audio.isPlaying {
                s.audio.play()
                s.audio.setRate(Float(s.speed))
            } else if s.live == nil {
                s.playing = true
            }
            return .success
        }

        cc.pauseCommand.addTarget { [weak self] _ in
            guard let s = self?.state else { return .noActionableNowPlayingItem }
            if s.live != nil { s.audio.pause() } else { s.playing = false }
            return .success
        }

        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.state?.togglePlay()
            return .success
        }

        cc.skipBackwardCommand.preferredIntervals = [15]
        cc.skipBackwardCommand.addTarget { [weak self] _ in
            self?.state?.skipBack15()
            return .success
        }

        cc.skipForwardCommand.preferredIntervals = [15]
        cc.skipForwardCommand.addTarget { [weak self] _ in
            self?.state?.skipFwd15()
            return .success
        }

        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self?.state?.seek(event.positionTime)
            return .success
        }
    }

    // MARK: - Now Playing info

    /// Replace the current Now Playing snapshot. Call when the episode changes
    /// or any metadata-affecting state changes (title, duration).
    func setEpisode(title: String, show: String, duration: Double?) {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = title
        info[MPMediaItemPropertyArtist] = show
        info[MPMediaItemPropertyPodcastTitle] = show
        if let duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Lightweight update for the position/rate without rebuilding the snapshot.
    func updatePlayback(elapsed: Double, rate: Double, playing: Bool) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? rate : 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Clear when the player closes / no episode is active.
    func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
