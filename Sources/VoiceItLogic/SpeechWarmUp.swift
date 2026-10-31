import Foundation

/// The speech model's first transcription after a pause takes about 330 ms instead of about 90 ms (measured: the penalty appears
/// somewhere between 5 and 20 s of idle). Running one short throwaway pass while the user is speaking removes it.
public enum SpeechWarmUp {
    /// No warm-up if the speech model was used this recently: it is still awake.
    public static let quietSeconds: TimeInterval = 5

    /// At key-down: run a warm-up pass? `lastUse` is the uptime of the last transcription or warm-up (nil if there has been none).
    public static func shouldWarm(lastUse: TimeInterval?, now: TimeInterval) -> Bool {
        guard let lastUse else { return true }
        return now - lastUse >= quietSeconds
    }
}
