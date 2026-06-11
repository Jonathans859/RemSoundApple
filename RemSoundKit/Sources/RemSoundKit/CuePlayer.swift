import AVFAudio
import Foundation

/// Plays the connect / disconnect cue sounds (the same WAVs the Windows app ships). Cues are
/// an accessibility feature: a screen-reader user hears peers come and go without having to
/// poll the UI.
public final class CuePlayer {
    public enum Cue: String, CaseIterable {
        case connect
        case disconnect
    }

    private var players: [Cue: AVAudioPlayer] = [:]
    public var enabled = true

    public init(bundle: Bundle = .main) {
        for cue in Cue.allCases {
            if let url = bundle.url(forResource: cue.rawValue, withExtension: "wav"),
               let player = try? AVAudioPlayer(contentsOf: url) {
                player.prepareToPlay()
                players[cue] = player
            }
        }
    }

    public func play(_ cue: Cue) {
        guard enabled, let player = players[cue] else { return }
        player.currentTime = 0
        player.play()
    }
}
