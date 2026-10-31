import Foundation
import Testing
@testable import VoiceItLogic

@Suite("Setup flow")
struct SetupPlanTests {
    func state(_ edit: (inout SetupState) -> Void = { _ in }) -> SetupState { var s = SetupState(); edit(&s); return s }

    @Test func theStepsRunInTheDocumentsOrder() {
        #expect(SetupStep.allCases == [.welcome, .moveToApplications, .requirements, .models, .permissions, .tryIt, .menuBar])
        #expect(SetupStep.allCases.allSatisfy { !$0.title.isEmpty })
    }

    @Test func aMacThatFailsTheRequirementsCannotGoPastThem() {
        #expect(!SetupPlan.canContinue(from: .requirements, state { $0.requirementsCanContinue = false }))
        #expect(SetupPlan.canContinue(from: .requirements, state()))
    }

    @Test func theSpeechModelIsRequiredAndTheCleanupModelOnlyIfAsked() {
        #expect(!SetupPlan.canContinue(from: .models, state()))
        #expect(SetupPlan.canContinue(from: .models, state { $0.speechInstalled = true }))
        #expect(!SetupPlan.canContinue(from: .models, state { $0.speechInstalled = true; $0.wantsCleanup = true }))
        #expect(SetupPlan.canContinue(from: .models, state { $0.speechInstalled = true; $0.wantsCleanup = true; $0.cleanupInstalled = true }))
    }

    @Test func theMenuBarExplainerNeverBlocksBecauseThePreparationHappensBehindIt() {
        #expect(SetupPlan.canContinue(from: .menuBar, state()))
        #expect(SetupPlan.canContinue(from: .menuBar, state { $0.speechInstalled = true }))          // the model may still be compiling: no waiting
    }

    @Test func microphoneAndInputMonitoringAreRequiredAccessibilityIsRecommended() {
        #expect(!SetupPlan.canContinue(from: .permissions, state()))
        #expect(!SetupPlan.canContinue(from: .permissions, state { $0.microphoneGranted = true }))
        #expect(!SetupPlan.canContinue(from: .permissions, state { $0.inputMonitoringGranted = true }))
        #expect(SetupPlan.canContinue(from: .permissions, state { $0.microphoneGranted = true; $0.inputMonitoringGranted = true }))
    }

    @Test func theFirstAndLastStepsNeverBlockAndNotNowIsAWayPastTheMove() {
        #expect(SetupPlan.canContinue(from: .welcome, state()) && SetupPlan.canContinue(from: .tryIt, state()))
        #expect(SetupPlan.canContinue(from: .moveToApplications, state()))
    }

    @Test func theWindowReopensAtTheFirstStepThatStillNeedsSomething() {
        #expect(SetupPlan.firstStepNeedingAttention(state()) == .models)
        #expect(SetupPlan.firstStepNeedingAttention(state { $0.speechInstalled = true }) == .permissions)         // the explainer and the compile never hold anyone up
        #expect(SetupPlan.firstStepNeedingAttention(state { $0.speechInstalled = true; $0.speechModelReady = true }) == .permissions)
        #expect(SetupPlan.firstStepNeedingAttention(state { $0.requirementsCanContinue = false }) == .requirements)
        let done = state { $0.speechInstalled = true; $0.speechModelReady = true; $0.microphoneGranted = true; $0.inputMonitoringGranted = true }
        #expect(SetupPlan.firstStepNeedingAttention(done) == .tryIt)
    }

    @Test func theCleanupModelIsTickedByDefaultOnlyOnBigMacs() {
        #expect(SetupPlan.defaultWantsCleanup(memoryBytes: 16 << 30))
        #expect(SetupPlan.defaultWantsCleanup(memoryBytes: 32 << 30))
        #expect(!SetupPlan.defaultWantsCleanup(memoryBytes: 8 << 30))
        #expect(!SetupPlan.defaultWantsCleanup(memoryBytes: 15 << 30))
    }

    @Test func aMacThatIsAlreadyWorkingIsLeftAlone() {
        #expect(!SetupPlan.shouldOpenAtLaunch(speechInstalled: true, setupDone: false, allPermissionsGranted: true))
        #expect(!SetupPlan.shouldOpenAtLaunch(speechInstalled: true, setupDone: true, allPermissionsGranted: false))   // set up before; the menu says what is off
        #expect(SetupPlan.shouldOpenAtLaunch(speechInstalled: true, setupDone: false, allPermissionsGranted: false))   // a first launch with something to allow
        #expect(SetupPlan.shouldOpenAtLaunch(speechInstalled: false, setupDone: true, allPermissionsGranted: true))    // a model went missing
    }

    @Test func onlyWhatIsMissingIsDownloaded() {
        #expect(SetupPlan.modelsToFetch(speechInstalled: false, cleanupInstalled: false, wantsCleanup: true) == ["speech", "cleanup"])
        #expect(SetupPlan.modelsToFetch(speechInstalled: false, cleanupInstalled: false, wantsCleanup: false) == ["speech"])
        #expect(SetupPlan.modelsToFetch(speechInstalled: true, cleanupInstalled: false, wantsCleanup: true) == ["cleanup"])
        #expect(SetupPlan.modelsToFetch(speechInstalled: true, cleanupInstalled: true, wantsCleanup: true).isEmpty)
        #expect(SetupPlan.modelsToFetch(speechInstalled: true, cleanupInstalled: false, wantsCleanup: false).isEmpty)
    }
}
