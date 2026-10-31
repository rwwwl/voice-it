import Foundation

/// The hold-to-talk and hands-free rules as a plain state machine: inputs in, actions out, no timers and no microphone,
/// so every case can be unit-tested. `HoldToTalkController` feeds it real events and carries out the actions.
///
///  * Hold the hotkey to record, release to finish (hold to talk). A hold shorter than `minHold` is a tap and is discarded.
///  * Press Shift at any time during the hold, then release: recording carries on (hands-free).
///  * Hands-free ends with the hotkey again or the Done button (processed), or with Escape or the X button (discarded).
///  * Hold the copy modifier too (Right Command by default) and the text is copied instead of pasted. If Shift is held as well,
///    copy wins and hands-free is ignored (nothing is pasted, which is the safer outcome).
///  * Any other key or modifier during a hold, or Escape, cancels it. Shift and the copy modifier are the exceptions.
public struct HotkeyMachine {
    public enum State: Equatable, Sendable { case idle, holding, handsFree }

    public enum Input: Equatable, Sendable {
        /// The hotkey went down. `shift` and `copy` say whether Shift and the copy modifier were already down at that moment.
        case hotkeyDown(shift: Bool, copy: Bool = false, at: TimeInterval)
        case hotkeyUp(at: TimeInterval)
        case shift(down: Bool)
        case copyModifier(down: Bool)
        /// Another key, or another modifier, went down while the hotkey was held.
        case otherKey
        case escape
        /// The Done button.
        case done
        /// The X button.
        case cancelButton
        /// A limit was reached in hands-free mode (too long, or too long without speech): finish as if Done was pressed.
        case autoStop
        /// The Mac is going to sleep or the microphone went away: keep what was captured in hands-free, drop a hold.
        case interrupted
        /// The recording could not start (microphone blocked, no input device).
        case startFailed
    }

    public enum Action: Equatable, Sendable {
        case startRecording
        /// Released too quickly: throw the recording away.
        case discardTap
        /// Released after a proper hold: finish through the adaptive tail, then process. `copyOnly`: copy the text, don't paste it.
        case finishHold(held: TimeInterval, copyOnly: Bool = false)
        case enterHandsFree
        /// Stop now and process what was recorded.
        case finishHandsFree
        /// Stop and throw the recording away.
        case cancel
    }

    public private(set) var state: State = .idle
    public var minHold: TimeInterval
    private var pressedAt: TimeInterval = 0
    private var shiftSeen = false
    private var copySeen = false
    /// After the hotkey press that ends hands-free, its release must not count as anything.
    private var swallowNextUp = false

    public init(minHold: TimeInterval = 0.3) { self.minHold = minHold }

    public mutating func handle(_ input: Input) -> [Action] {
        switch state {
        case .idle:
            switch input {
            case .hotkeyDown(let shift, let copy, let at):
                state = .holding; pressedAt = at; shiftSeen = shift; copySeen = copy; swallowNextUp = false
                return [.startRecording]
            case .hotkeyUp:
                swallowNextUp = false
                return []
            default: return []
            }
        case .holding:
            switch input {
            case .shift(let down):
                if down { shiftSeen = true }
                return []
            case .copyModifier(let down):
                if down { copySeen = true }
                return []
            case .hotkeyUp(let at):
                let held = at - pressedAt
                if shiftSeen && !copySeen { state = .handsFree; return [.enterHandsFree] }      // exempt from the tap rule
                state = .idle
                return held < minHold ? [.discardTap] : [.finishHold(held: held, copyOnly: copySeen)]
            case .otherKey, .escape, .cancelButton, .interrupted:
                state = .idle
                return [.cancel]
            case .startFailed:
                state = .idle
                return []
            default: return []
            }
        case .handsFree:
            switch input {
            case .hotkeyDown:
                state = .idle; swallowNextUp = true
                return [.finishHandsFree]
            case .done, .autoStop, .interrupted:
                state = .idle
                return [.finishHandsFree]
            case .escape, .cancelButton:
                state = .idle
                return [.cancel]
            default: return []      // typing, Shift and the release of the first hold do nothing
            }
        }
    }
}
