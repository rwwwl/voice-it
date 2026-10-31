import Foundation

/// Hard-coded for Stage 1. Moves to the JSON config file in a later stage.
public enum Defaults {
    /// Holds shorter than this are treated as accidental taps and ignored.
    public static let minHoldDuration: TimeInterval = 0.3
    /// Parakeet expects 16 kHz mono.
    public static let sampleRate: Double = 16_000
}

extension Defaults {
    /// 20 ms windows with RMS above this count as voiced.
    public static let speechRMSThresholdDBFS: Double = -42
    /// Less voiced audio than this in total is treated as silence and nothing is pasted.
    public static let minVoicedDuration: TimeInterval = 0.15
    /// Delay between posting Cmd-V and restoring the clipboard, so the target app can read it first.
    public static let clipboardRestoreDelay: TimeInterval = 0.4
}

extension Defaults {
    /// After the key is released, recording continues until this much silence has been heard...
    public static let tailSilence: TimeInterval = 0.15
    /// ...but never longer than this after the release.
    public static let tailMax: TimeInterval = 0.6
}

extension Defaults {
    /// Hands-free recording stops by itself after this long...
    public static let handsFreeMax: TimeInterval = 300
    /// ...and the pill counts down for this many seconds before that happens.
    public static let handsFreeWarning: TimeInterval = 30
    /// ...or after this long without any speech.
    public static let handsFreeSilence: TimeInterval = 30
    /// For a long dictation the cleanup model gets at most this long in total; pieces after that are pasted with the rules only.
    public static let cleanupBudget: TimeInterval = 15
}

extension Defaults {
    /// How much freed GPU memory the cleanup runtime may keep for reuse. Unlimited, it grew to about 3 GB after a few dozen dictations;
    /// at this size the footprint stays near the model's own and cleanup is about 14 ms slower (NOTES, entry 89).
    public static let mlxCacheLimitBytes = 128 << 20
}
