import Foundation

/// The steps of the setup window, in order. The Applications step is left out when the app already sits in Applications.
public enum SetupStep: Int, CaseIterable, Sendable {
    case welcome, moveToApplications, requirements, models, permissions, tryIt, menuBar

    public var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .moveToApplications: return "Applications"
        case .requirements: return "This Mac"
        case .models: return "Models"
        case .menuBar: return "Menu bar"
        case .permissions: return "Permissions"
        case .tryIt: return "Try it"
        }
    }
}

/// What the setup window knows, gathered from the Mac. Pure data, so the flow can be tested.
public struct SetupState: Equatable, Sendable {
    public var requirementsCanContinue = true
    public var speechInstalled = false
    public var cleanupInstalled = false
    public var wantsCleanup = false
    public var speechModelReady = false
    public var microphoneGranted = false
    public var inputMonitoringGranted = false
    public var accessibilityGranted = false
    public init() {}
}

public enum SetupPlan {
    /// The cleanup model is offered, and ticked by default, on Macs with 16 GB or more.
    public static func defaultWantsCleanup(memoryBytes: UInt64) -> Bool { memoryBytes >= Requirements.fullCleanupMemoryBytes }

    /// May the person move on from this step? Nothing is skipped silently: a step that has to be finished says so.
    public static func canContinue(from step: SetupStep, _ s: SetupState) -> Bool {
        switch step {
        case .welcome, .tryIt: return true
        case .moveToApplications: return true      // "Not now" is a way forward
        case .requirements: return s.requirementsCanContinue
        case .models: return s.speechInstalled && (!s.wantsCleanup || s.cleanupInstalled)
        case .menuBar: return true               // the closing explainer; the speech model prepares itself in the background meanwhile
        // Accessibility is strongly recommended but not required: without it the text is copied instead of pasted.
        case .permissions: return s.microphoneGranted && s.inputMonitoringGranted
        }
    }

    /// Where to start when the window opens for a reason: the first step that still needs something.
    public static func firstStepNeedingAttention(_ s: SetupState) -> SetupStep {
        SetupStep.allCases.first { !canContinue(from: $0, s) } ?? .tryIt
    }

    /// Open the window by itself at launch? When a model is missing, or on a first launch where something still has to be allowed.
    /// A Mac that is already set up and working is left alone.
    public static func shouldOpenAtLaunch(speechInstalled: Bool, setupDone: Bool, allPermissionsGranted: Bool) -> Bool {
        !speechInstalled || (!setupDone && !allPermissionsGranted)
    }

    /// Which models a download of this choice fetches, and what is already there.
    public static func modelsToFetch(speechInstalled: Bool, cleanupInstalled: Bool, wantsCleanup: Bool) -> [String] {
        var ids: [String] = []
        if !speechInstalled { ids.append("speech") }
        if wantsCleanup && !cleanupInstalled { ids.append("cleanup") }
        return ids
    }
}
