import Foundation

/// The hold-to-talk key. Only modifier keys are offered: they can be held while speaking and tell left from right,
/// which keeps them clear of ordinary typing. (The Fn/Globe key is left out on purpose: it conflicts with system dictation.)
public enum Hotkey: String, Codable, CaseIterable, Sendable {
    case rightOption, leftOption, rightCommand, leftCommand, rightControl, leftControl, rightShift, leftShift

    public var isShift: Bool { self == .rightShift || self == .leftShift }

    /// The virtual key code of the physical key.
    public var keyCode: Int64 {
        switch self {
        case .rightOption: return 61
        case .leftOption: return 58
        case .rightCommand: return 54
        case .leftCommand: return 55
        case .rightControl: return 62
        case .leftControl: return 59
        case .rightShift: return 60
        case .leftShift: return 56
        }
    }

    /// The bit in the event flags that is set while this particular physical key (not just the modifier) is down.
    public var deviceMask: UInt64 {
        switch self {
        case .rightOption: return 0x40       // NX_DEVICERALTKEYMASK
        case .leftOption: return 0x20        // NX_DEVICELALTKEYMASK
        case .rightCommand: return 0x10      // NX_DEVICERCMDKEYMASK
        case .leftCommand: return 0x08       // NX_DEVICELCMDKEYMASK
        case .rightControl: return 0x2000    // NX_DEVICERCTLKEYMASK
        case .leftControl: return 0x01       // NX_DEVICELCTLKEYMASK
        case .rightShift: return 0x04        // NX_DEVICERSHIFTKEYMASK
        case .leftShift: return 0x02         // NX_DEVICELSHIFTKEYMASK
        }
    }

    /// The symbol printed on the key: ⌥ ⌘ ⌃ ⇧.
    public var symbol: String {
        switch self {
        case .rightOption, .leftOption: return "⌥"
        case .rightCommand, .leftCommand: return "⌘"
        case .rightControl, .leftControl: return "⌃"
        case .rightShift, .leftShift: return "⇧"
        }
    }

    /// The word printed on the key: "option", "command", "control" or "shift".
    public var keyWord: String {
        switch self {
        case .rightOption, .leftOption: return "option"
        case .rightCommand, .leftCommand: return "command"
        case .rightControl, .leftControl: return "control"
        case .rightShift, .leftShift: return "shift"
        }
    }

    public var isRightSide: Bool {
        switch self { case .rightOption, .rightCommand, .rightControl, .rightShift: return true; default: return false }
    }

    public var displayName: String {
        switch self {
        case .rightOption: return "Right Option"
        case .leftOption: return "Left Option"
        case .rightCommand: return "Right Command"
        case .leftCommand: return "Left Command"
        case .rightControl: return "Right Control"
        case .leftControl: return "Left Control"
        case .rightShift: return "Right Shift"
        case .leftShift: return "Left Shift"
        }
    }
}
