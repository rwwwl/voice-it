import Foundation
import Testing
@testable import VoiceItLogic

@Suite("Requirements check")
struct RequirementsTests {
    let gb: UInt64 = 1 << 30
    func facts(arm: Bool = true, macOS: OSVersion = OSVersion(15, 8, 1), memoryGB: UInt64 = 32, freeGB: Double = 200) -> SystemFacts {
        SystemFacts(isAppleSilicon: arm, macOS: macOS, memoryBytes: memoryGB * (1 << 30), freeDiskBytes: UInt64(freeGB * 1_000_000_000))
    }

    @Test func aCapableMacPassesEverything() {
        let r = Requirements.check(facts: facts(), models: .withCleanup)
        #expect(r.canContinue && r.failures.isEmpty && r.warnings.isEmpty)
        #expect(r.recommendedModels == .withCleanup)
        #expect(r.results.map(\.item) == [.appleSilicon, .macOS, .memory, .disk])
    }

    @Test func anIntelMacIsStoppedWithAPlainReason() {
        let r = Requirements.check(facts: facts(arm: false), models: .withCleanup)
        #expect(!r.canContinue)
        #expect(r.failures.first?.message == "Voice It needs a Mac with Apple silicon (M1 or later). This Mac has an Intel processor.")
        #expect(r.failures.first?.short == "Needs Apple silicon")
    }

    @Test func anOldMacOSIsStoppedAndSaysWhichVersionItHas() {
        let r = Requirements.check(facts: facts(macOS: OSVersion(14, 5)), models: .withCleanup)
        #expect(!r.canContinue)
        #expect(r.failures.first?.message == "Voice It needs macOS 15 (Sequoia) or later. This Mac has macOS 14.5.")
        #expect(Requirements.check(facts: facts(macOS: OSVersion(15, 0)), models: .withCleanup).canContinue)    // exactly the minimum is fine
        #expect(!Requirements.check(facts: facts(macOS: OSVersion(14, 99, 99)), models: .withCleanup).canContinue)
    }

    @Test func eightGBWarnsForTheCleanupModelButIsFineForSpeechOnly() {
        let full = Requirements.check(facts: facts(memoryGB: 8), models: .withCleanup)
        #expect(full.canContinue)                                    // a warning, not a stop
        #expect(full.warnings.count == 1 && full.warnings[0].item == .memory)
        #expect(full.warnings[0].message.contains("8 GB") && full.warnings[0].message.contains("Exact style"))
        #expect(full.recommendedModels == .speechOnly)
        let rulesOnly = Requirements.check(facts: facts(memoryGB: 8), models: .speechOnly)
        #expect(rulesOnly.warnings.isEmpty && rulesOnly.canContinue)
    }

    @Test func sixteenGBIsTheLineForTheCleanupModel() {
        #expect(Requirements.check(facts: facts(memoryGB: 16), models: .withCleanup).warnings.isEmpty)
        #expect(Requirements.check(facts: facts(memoryGB: 16), models: .withCleanup).recommendedModels == .withCleanup)
        #expect(Requirements.check(facts: facts(memoryGB: 15), models: .withCleanup).recommendedModels == .speechOnly)
    }

    @Test func belowEightGBIsAStop() {
        let r = Requirements.check(facts: facts(memoryGB: 4), models: .speechOnly)
        #expect(!r.canContinue)
        #expect(r.failures.first?.message == "Voice It needs at least 8 GB of memory. This Mac has 4 GB.")
    }

    @Test func diskNeedIncludesTheDownloadTheCompiledCopyAndAMargin() {
        let full = Requirements.requiredFreeBytes(for: .withCleanup), speech = Requirements.requiredFreeBytes(for: .speechOnly)
        #expect(full > ModelSizes.download(for: .withCleanup) + ModelSizes.speech)       // more than download plus compiled copy
        #expect(speech > 2 * ModelSizes.speech)
        #expect(full > speech)
        #expect(speech - 2 * ModelSizes.speech >= 500_000_000)                    // at least the 500 MB margin
    }

    @Test func notEnoughDiskStopsWithTheNumbers() {
        let r = Requirements.check(facts: facts(freeGB: 1.2), models: .withCleanup)
        #expect(!r.canContinue)
        let message = r.failures.first?.message ?? ""
        #expect(message.contains("isn't enough free disk space") && message.contains("1.2 GB free") && message.contains("2.7 GB"))
        #expect(r.failures.first?.short == "Not enough free disk space")
    }

    @Test func theSameDiskThatFailsWithTheCleanupModelCanBeEnoughWithoutIt() {
        #expect(!Requirements.check(facts: facts(freeGB: 2), models: .withCleanup).canContinue)
        #expect(Requirements.check(facts: facts(freeGB: 2), models: .speechOnly).canContinue)
    }

    @Test func theDiskLimitIsExactlyTheRequiredAmount() {
        let need = Requirements.requiredFreeBytes(for: .withCleanup)
        var f = facts(); f.freeDiskBytes = need
        #expect(Requirements.check(facts: f, models: .withCleanup).canContinue)
        f.freeDiskBytes = need - 1
        #expect(!Requirements.check(facts: f, models: .withCleanup).canContinue)
    }

    @Test func everyProblemIsReportedNotJustTheFirst() {
        let r = Requirements.check(facts: facts(arm: false, macOS: OSVersion(13, 6), memoryGB: 4, freeGB: 0.1), models: .withCleanup)
        #expect(r.failures.count == 4)
    }

    @Test func diskIsSkippedWhenAskedTo() {
        let r = Requirements.check(facts: facts(freeGB: 0.01), models: .withCleanup, checkDisk: false)
        #expect(r.canContinue && !r.results.contains { $0.item == .disk })
    }

    @Test func readingThisMacGivesSensibleValues() {
        let f = Requirements.currentFacts(at: URL(fileURLWithPath: "/nonexistent/folder/that/does/not/exist"))
        #expect(f.isAppleSilicon)                       // this project only builds for Apple silicon
        #expect(f.macOS >= OSVersion(15, 0))
        #expect(f.memoryBytes >= 8 << 30)
        #expect(f.freeDiskBytes > 0)                    // fell back to the nearest folder that exists
    }

    @Test func theSpeechModelAloneNeedsNoCleanupDownloadAndNoMemoryWarning() {
        #expect(ModelSizes.download(for: .speechOnly) == ModelSizes.speech)                    // no cleanup model to download
        #expect(ModelSizes.download(for: .withCleanup) == ModelSizes.speech + ModelSizes.cleanup)
        #expect(Requirements.requiredFreeBytes(for: .speechOnly) < Requirements.requiredFreeBytes(for: .withCleanup))
        let eightGB = Requirements.check(facts: facts(memoryGB: 8), models: .speechOnly)
        #expect(eightGB.warnings.isEmpty && eightGB.canContinue)
    }
}
