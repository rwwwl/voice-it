import Foundation
import Testing
@testable import VoiceItCore
@testable import VoiceItLogic

/// A transcriber that says one fixed sentence and counts how often it was asked.
final class FixedTranscriber: Transcriber, @unchecked Sendable {
    let words: String
    private let lock = NSLock()
    private var calls = 0
    init(_ words: String) { self.words = words }
    var transcriptions: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func load() async throws {}
    func warmUp() async {}
    func transcribe(samples: [Float]) async throws -> String { lock.lock(); calls += 1; lock.unlock(); return words }
    func transcribe(url: URL) async throws -> String { words }
}

/// Where the text would have gone: remembers it instead of touching the clipboard or sending Cmd-V.
final class RecordingOutput: TextOutput, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var pasted: [String] = [], copied: [String] = []
    @MainActor func paste(_ text: String) async -> TimeInterval { lock.lock(); pasted.append(text); lock.unlock(); return 0 }
    @MainActor func copy(_ text: String, transient: Bool) { lock.lock(); copied.append(text); lock.unlock() }
    var nothingWritten: Bool { lock.lock(); defer { lock.unlock() }; return pasted.isEmpty && copied.isEmpty }
}

@Suite("Password fields", .serialized)
struct PasswordFieldTests {
    let secret = "my password is hunter two"

    func recording() -> AudioRecorder.Result {
        AudioRecorder.Result(samples: [Float](repeating: 0.1, count: 32_000), duration: 2, peakDBFS: -10, voicedDuration: 2)
    }

    /// Runs one dictation through the real pipeline with the stand-ins and returns what happened. `secure` is asked once per check.
    func dictate(copyOnly: Bool = false, secure: @escaping () -> Bool, logTranscripts: Bool = false)
        async throws -> (report: DictationPipeline.Report, transcriber: FixedTranscriber, output: RecordingOutput) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("voice-it-pw-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ConfigStore(fileURL: folder.appendingPathComponent("config.json"))
        _ = store.update { $0.style = .exact; $0.debug.logTranscripts = logTranscripts }
        let transcriber = FixedTranscriber(secret), output = RecordingOutput()
        let pipeline = DictationPipeline(transcriber: transcriber, cleaner: nil, configStore: store, output: output, secureInput: secure)
        let report: DictationPipeline.Report = await withCheckedContinuation { c in
            nonisolated(unsafe) var resumed = false
            pipeline.onStatus = { if case .finished(let r) = $0, !resumed { resumed = true; c.resume(returning: r) } }
            pipeline.enqueue(recording(), releasedAt: ProcessInfo.processInfo.systemUptime, targetApp: nil, copyOnly: copyOnly)
        }
        return (report, transcriber, output)
    }

    @Test func aPasswordFieldMeansNoTranscriptionNoPasteNoCopy() async throws {
        let r = try await dictate(secure: { true })
        #expect(r.report.outcome == .blockedPasswordField)
        #expect(r.transcriber.transcriptions == 0)                       // the words are never even turned into text
        #expect(r.output.nothingWritten)
        #expect(r.report.text.isEmpty && r.report.rawText.isEmpty)
    }

    @Test func aDeliberateCopyIsBlockedToo() async throws {
        let r = try await dictate(copyOnly: true, secure: { true })
        #expect(r.report.outcome == .blockedPasswordField && r.output.nothingWritten)
    }

    @Test func focusMovingIntoAPasswordFieldWhileProcessingStillBlocksTheText() async throws {
        // Not secure when the dictation starts, secure by the time the text is ready to go out.
        nonisolated(unsafe) var asked = 0
        let r = try await dictate(copyOnly: true, secure: { asked += 1; return asked >= 2 })
        #expect(r.transcriber.transcriptions == 1)                       // it was transcribed...
        #expect(r.report.outcome == .blockedPasswordField)               // ...but nothing is written, and the report holds none of it
        #expect(r.output.nothingWritten)
        #expect(r.report.text.isEmpty && r.report.rawText.isEmpty)
    }

    @Test func nothingIsLoggedAboutTheWordsEvenWithTranscriptLoggingOn() async throws {
        let blocked = try await dictate(secure: { true }, logTranscripts: true)
        let line = DictationPipeline.logLine(blocked.report, includeText: true)
        #expect(!line.contains("hunter") && !line.contains("password is"))
        #expect(line.contains("blockedPasswordField"))
        // After transcription, too (the second check): the report is emptied before it is logged.
        nonisolated(unsafe) var asked = 0
        let late = try await dictate(copyOnly: true, secure: { asked += 1; return asked >= 2 }, logTranscripts: true)
        #expect(!DictationPipeline.logLine(late.report, includeText: true).contains("hunter"))
    }

    @Test func aBlockedDictationIsNeverRememberedOrWrittenToHistory() {
        #expect(!DictationPipeline.Outcome.blockedPasswordField.isStorable)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voice-it-pw-hist-\(UUID().uuidString)"); defer { try? FileManager.default.removeItem(at: dir) }
        let store = LastDictationStore(fileURL: dir.appendingPathComponent("history.jsonl"))
        // The app records only storable outcomes; this is the rule it follows.
        for outcome in [DictationPipeline.Outcome.blockedPasswordField] where outcome.isStorable { store.record(raw: "x", text: "x", history: true) }
        #expect(store.last(history: true) == nil && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("history.jsonl").path))
    }

    @Test func withoutAPasswordFieldTheSameDictationGoesThrough() async throws {
        let r = try await dictate(copyOnly: true, secure: { false })
        #expect(r.report.outcome == .copied)
        #expect(r.output.copied == [secret])                             // so the tests above fail for the right reason
        #expect(r.transcriber.transcriptions == 1)
    }

    @Test func holdingTheHotkeyInAPasswordFieldDoesNotRecord() {
        let controller = HoldToTalkController()
        controller.secureInput = { true }
        var states: [HoldToTalkController.State] = []
        controller.onState = { states.append($0) }
        controller.handle(.pressed(shift: false, copy: false))
        #expect(states == [.passwordField])
        #expect(!controller.isHandsFree)
        controller.handle(.released)                                     // a release after the refused press does nothing
        #expect(states == [.passwordField])
    }
}
