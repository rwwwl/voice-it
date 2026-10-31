import Foundation

/// The one-line status at the top of the menu. Decided here, away from the menu code, so the priorities can be tested.
public enum MenuStatus: Equatable {
    case ready
    case setupNeeded
    case loadingModel
    case modelFailed
    case microphoneOff
    case inputMonitoringOff
    case settingsError
    case unsupported(String)

    public var text: String {
        switch self {
        case .ready: return "Ready"
        case .setupNeeded: return "Setup needed"
        case .loadingModel: return "Loading the model…"
        case .modelFailed: return "Couldn't load the speech model"
        case .microphoneOff: return "Microphone access is off"
        case .inputMonitoringOff: return "Input Monitoring is off, the hotkey can't work"
        case .settingsError: return "Settings error"
        case .unsupported(let why): return why
        }
    }

    /// The most important thing wrong wins: a Mac that can't run the app, then a broken settings file, a missing speech model, then permissions, then the model.
    public static func decide(unsupported: String?, settingsError: Bool, microphoneOff: Bool, inputMonitoringOff: Bool,
                              modelFailed: Bool, modelLoading: Bool, setupNeeded: Bool = false) -> MenuStatus {
        if let unsupported { return .unsupported(unsupported) }
        if settingsError { return .settingsError }
        if setupNeeded { return .setupNeeded }          // no speech model on this Mac yet: nothing else matters until it is installed
        if microphoneOff { return .microphoneOff }
        if inputMonitoringOff { return .inputMonitoringOff }
        if modelFailed { return .modelFailed }
        if modelLoading { return .loadingModel }
        return .ready
    }
}
