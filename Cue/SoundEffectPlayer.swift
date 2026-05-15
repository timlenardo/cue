import AVFoundation
import os.log

@MainActor
final class SoundEffectPlayer {
    static let shared = SoundEffectPlayer()

    enum Effect: String, CaseIterable {
        case voiceReady = "orbit-aurora-chime"
    }

    private let log = Logger(subsystem: "com.cue.app", category: "sound-effect")
    private var players: [Effect: AVAudioPlayer] = [:]

    private init() {
        Effect.allCases.forEach(preload)
    }

    private func preload(_ effect: Effect) {
        for ext in ["wav", "m4a", "caf", "aiff"] {
            guard let url = Bundle.main.url(forResource: effect.rawValue, withExtension: ext) else {
                continue
            }
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay()
                players[effect] = player
                return
            } catch {
                log.error("load \(effect.rawValue, privacy: .public).\(ext, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        log.warning("missing bundled sound: \(effect.rawValue, privacy: .public)")
    }

    func play(_ effect: Effect) {
        guard let player = players[effect] else { return }
        player.currentTime = 0
        player.play()
    }
}
