import AppKit

/// Subtle system-sound feedback for recording start/stop, matching what
/// dictation tools users expect. Uses built-in sounds — nothing to bundle.
public enum SoundPlayer {
    public enum Cue {
        case start, stop, error

        var soundName: String {
            switch self {
            case .start: return "Tink"
            case .stop: return "Pop"
            case .error: return "Basso"
            }
        }
    }

    public static func play(_ cue: Cue) {
        NSSound(named: cue.soundName)?.play()
    }
}
