import Foundation
import Testing
@testable import VoiceItLogic

@Suite("Config file")
struct ConfigTests {
    func decode(_ json: String) throws -> Config { try JSONDecoder().decode(Config.self, from: Data(json.utf8)) }

    @Test func anEmptyFileGivesAllTheDefaults() throws {
        let c = try decode("{}")
        #expect(c == Config())
        #expect(c.hotkey == .rightOption)
        #expect(c.debug.logTranscripts == false)
        #expect(c.cleanup.timeoutSeconds == 3)
    }

    @Test func missingKeysFallBackToDefaultsInsideNestedObjects() throws {
        let c = try decode(#"{"cleanup": {"model": "some-model"}}"#)
        #expect(c.cleanup.model == "some-model")
        #expect(c.style == .natural)
        #expect(c.cleanup.timeoutSeconds == 3)
    }

    @Test func theVocabularyIsEmptyByDefaultSoASharedBuildShipsNobodysWords() throws {
        #expect(Config().dictionary.isEmpty && Config().snippets.isEmpty)
        #expect(try decode("{}").dictionary.isEmpty)
        #expect(!Config.exampleDictionary.isEmpty)                                  // the project's own samples keep theirs, as an explicit list
        let kept = try decode(#"{"dictionary": [{"term": "Mine", "heardAs": ["mind"]}]}"#)
        #expect(kept.dictionary == [Config.DictionaryEntry(term: "Mine", heardAs: ["mind"])])      // an owner's file keeps its entries
    }

    @Test func debugLoggingIsOffUnlessTurnedOn() throws {
        #expect(try decode("{}").debug.logTranscripts == false)
        #expect(try decode(#"{"debug": {"logTranscripts": true}}"#).debug.logTranscripts == true)
    }

    @Test func keepingAudioIsOffUnlessTurnedOn() throws {
        #expect(try decode("{}").debug.keepAudio == false)
        #expect(try decode(#"{"debug": {"keepAudio": true}}"#).debug.keepAudio == true)
        #expect(try decode(#"{"debug": {"logTranscripts": true}}"#).debug.keepAudio == false)   // the two options are independent
    }

    @Test func hotkeyCanBeChosenAndAnUnknownNameIsAnError() throws {
        #expect(try decode(#"{"hotkey": "leftCommand"}"#).hotkey == .leftCommand)
        #expect(throws: DecodingError.self) { try decode(#"{"hotkey": "capsLock"}"#) }
    }

    @Test func aConfigSurvivesBeingWrittenAndReadBack() throws {
        var c = Config()
        c.hotkey = .rightControl
        c.debug.logTranscripts = true
        c.snippets = [Config.Snippet(trigger: "my address", expansion: "1 Example Street")]
        let data = try JSONEncoder().encode(c)
        #expect(try JSONDecoder().decode(Config.self, from: data) == c)
    }

    @Test func theCleanupModelFolderIsUnderApplicationSupport() {
        let url = Config().cleanupModelDirectory
        #expect(url.path.hasSuffix("Voice It/models/cleanup/Qwen3-4B-Instruct-2507-4bit"))
    }
}

@Suite("Display choice")
struct StageSevenLogicTests {
    @Test func theOverlayGoesToTheDisplayShowingMostOfTheWindow() {
        let left = CGRect(x: 0, y: 0, width: 1000, height: 800), right = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        #expect(ScreenPicker.index(forWindow: CGRect(x: 100, y: 100, width: 400, height: 300), screens: [left, right]) == 0)
        #expect(ScreenPicker.index(forWindow: CGRect(x: 1200, y: 100, width: 400, height: 300), screens: [left, right]) == 1)
        // A window straddling the two displays: the one with more of it wins.
        #expect(ScreenPicker.index(forWindow: CGRect(x: 800, y: 100, width: 500, height: 300), screens: [left, right]) == 1)
        #expect(ScreenPicker.index(forWindow: CGRect(x: 800, y: 100, width: 300, height: 300), screens: [left, right]) == 0)
    }

    @Test func aWindowOnNoDisplayGivesNil() {
        #expect(ScreenPicker.index(forWindow: CGRect(x: 5000, y: 5000, width: 10, height: 10), screens: [CGRect(x: 0, y: 0, width: 100, height: 100)]) == nil)
        #expect(ScreenPicker.index(forWindow: CGRect(x: 0, y: 0, width: 10, height: 10), screens: []) == nil)
    }
}

@Suite("Launch at login")
struct LoginItemTests {
    func tempHome() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("voice-it-home-\(UUID().uuidString)") }

    @Test func theAgentFileIsAValidPropertyListThatOpensTheApp() throws {
        let data = LoginItem.plist(appPath: "/Users/me/Applications/Voice It.app")
        let dict = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(dict["Label"] as? String == "io.github.rwwwl.voice-it.login")
        #expect(dict["RunAtLoad"] as? Bool == true)
        #expect(dict["ProgramArguments"] as? [String] == ["/usr/bin/open", "-g", "-a", "/Users/me/Applications/Voice It.app"])
    }

    @Test func unusualCharactersInThePathSurvive() {
        let path = "/Users/me/My Apps & Tools/Voice It <beta>.app"
        #expect(LoginItem.appPath(in: LoginItem.plist(appPath: path)) == path)
    }

    @Test func enablingAndDisablingWritesAndRemovesTheFile() throws {
        let home = tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let app = "/Applications/Voice It.app"
        #expect(!LoginItem.isEnabled(for: app, home: home))
        #expect(LoginItem.enable(appPath: app, home: home))
        #expect(LoginItem.isEnabled(for: app, home: home))
        #expect(FileManager.default.fileExists(atPath: LoginItem.agentURL(home: home).path))
        #expect(!LoginItem.isEnabled(for: "/somewhere/else/Voice It.app", home: home))   // points at a different copy
        #expect(LoginItem.disable(home: home))
        #expect(!LoginItem.isEnabled(for: app, home: home))
        #expect(LoginItem.disable(home: home))                                           // already off is fine
    }
}

@Suite("About credits")
struct AttributionsTests {
    func text(repo: String? = nil) -> String {
        Attributions.sections(version: "0.1.0 (build 1, abc1234)", copyrightHolder: "rwwwl", year: "2026", repoURL: repo)
            .flatMap { [$0.heading] + $0.lines }.joined(separator: "\n")
    }

    @Test func theCreditsRequiredByTheModelAndCodeLicencesArePresent() {
        let t = text()
        #expect(t.contains("NVIDIA") && t.contains("CC BY 4.0") && t.contains("creativecommons.org/licenses/by/4.0"))   // Parakeet: attribution and licence link
        #expect(t.contains("converted to Core ML"))                                                                       // statement of changes
        #expect(t.contains("Qwen3-4B-Instruct-2507") && t.contains("Apache License 2.0"))
        #expect(t.contains("FluidAudio") && t.contains("MLX") && t.contains("THIRD_PARTY_LICENSES.md"))
    }

    @Test func theAppSaysWhoOwnsItUnderWhichLicenceAndWhichVersionThisIs() {
        let t = text()
        #expect(t.contains("Copyright © 2026 rwwwl") && t.contains("GNU General Public License, version 3"))
        #expect(t.contains("0.1.0 (build 1, abc1234)"))
    }

    @Test func theSourceLinkAppearsOnlyOnceThereIsOne() {
        #expect(!text().contains("Source code:"))
        #expect(!text(repo: "").contains("Source code:"))
        #expect(text(repo: "https://github.com/rwwwl/voice-it").contains("Source code: https://github.com/rwwwl/voice-it"))
    }
}


@Suite("Safe settings")
struct SafeSettingsTests {
    func tempFile() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voice-it-config-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }
    func cleanUp(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    /// Writes `text` and makes sure the modification date differs from the previous write (the store reloads on a changed date).
    func write(_ text: String, to url: URL, secondsAhead: Double) throws {
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(secondsAhead)], ofItemAtPath: url.path)
    }

    func problem(_ json: String) -> ConfigProblem? {
        let data = Data(json.utf8)
        do { _ = try JSONDecoder().decode(Config.self, from: data); return nil }
        catch { return ConfigProblem.diagnose(error, in: data) }
    }

    // MARK: Naming the problem and where it is

    @Test func aSyntaxErrorGetsALineAndColumn() throws {
        let p = try #require(problem("{\n  \"hotkey\": \"rightOption\",\n  \"cleanup\": { \"mode\": \"full\" \n  \"model\": \"x\"\n}"))
        #expect(p.line != nil && p.column != nil)
        #expect(p.message.hasPrefix("not valid JSON"))
        #expect((3...5).contains(p.line ?? 0))     // at or just after the missing comma
    }

    @Test func anUnknownHotkeyNamesTheSettingAndItsLine() throws {
        let p = try #require(problem("{\n  \"style\": \"natural\",\n  \"hotkey\": \"capsLock\"\n}"))
        #expect(p.message.contains("\"hotkey\"") && p.message.contains("capsLock") && p.message.contains("rightOption"))
        #expect(p.line == 3)
    }

    @Test func anUnknownStyleIsReportedOnItsLine() throws {
        let p = try #require(problem("{\n  \"cleanup\": {},\n  \"style\": \"sometimes\"\n}"))
        #expect(p.message.contains("\"style\"") && p.message.contains("sometimes"))
        #expect(p.line == 3)
    }

    @Test func aWrongKindOfValueSaysWhatWasExpected() throws {
        let p = try #require(problem("{\n  \"cleanup\": { \"timeoutSeconds\": \"fast\" }\n}"))
        #expect(p.message.contains("a number") && p.message.contains("timeoutSeconds"))
        #expect(p.line == 2)
    }

    @Test func aGoodFileHasNoProblem() {
        #expect(problem("{}") == nil)
        #expect(problem(#"{"hotkey": "leftCommand"}"#) == nil)
    }

    @Test func summaryReadsLikeAnInstruction() {
        #expect(ConfigProblem(message: "oops", line: 4, column: 9).summary == "line 4, column 9: oops")
        #expect(ConfigProblem(message: "oops").summary == "oops")
    }

    // MARK: Never losing the owner's settings

    @Test func aBrokenEditKeepsTheLastGoodSettingsAndNeverTouchesTheFile() throws {
        let url = tempFile(); defer { cleanUp(url) }
        try write(#"{"hotkey": "leftCommand"}"#, to: url, secondsAhead: -20)
        let store = ConfigStore(fileURL: url)
        #expect(store.current().hotkey == .leftCommand)
        #expect(store.problem == nil)

        let broken = #"{"hotkey": "leftCommand""#      // a missing closing brace
        try write(broken, to: url, secondsAhead: -10)
        #expect(store.current().hotkey == .leftCommand)  // still the last good
        #expect(store.problem != nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == broken)   // the owner's file is exactly as they left it

        try write(#"{"hotkey": "rightControl"}"#, to: url, secondsAhead: -5)    // fixed
        #expect(store.current().hotkey == .rightControl)
        #expect(store.problem == nil)
    }

    @Test func aRestartWithABrokenFileUsesTheLastGoodCopyOnDisk() throws {
        let url = tempFile(); defer { cleanUp(url) }
        try write(#"{"hotkey": "leftCommand"}"#, to: url, secondsAhead: -20)
        _ = ConfigStore(fileURL: url).current()                       // first launch: a good load saves config.lastgood.json
        let broken = "{ not json"
        try write(broken, to: url, secondsAhead: -10)
        let relaunched = ConfigStore(fileURL: url)                    // a new launch, with the file now broken
        #expect(relaunched.current().hotkey == .leftCommand)
        #expect(relaunched.problem != nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == broken)
    }

    @Test func aBrokenFileWithNoLastGoodCopyUsesDefaultsButIsNotOverwritten() throws {
        let url = tempFile(); defer { cleanUp(url) }
        try write("{ not json", to: url, secondsAhead: -10)
        let store = ConfigStore(fileURL: url)
        #expect(store.current() == Config())
        #expect(store.problem != nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == "{ not json")
    }

    @Test func editsFromInsideTheAppAreRefusedWhileTheFileHasAnError() throws {
        let url = tempFile(); defer { cleanUp(url) }
        try write("{ not json", to: url, secondsAhead: -10)
        let store = ConfigStore(fileURL: url)
        #expect(store.update { $0.style = .exact } == false)
        #expect(try String(contentsOf: url, encoding: .utf8) == "{ not json")
    }

    @Test func aMissingFileIsCreatedWithDefaultsOnlyWhenThereIsNothingToRestore() throws {
        let url = tempFile(); defer { cleanUp(url) }
        let store = ConfigStore(fileURL: url)
        #expect(store.current() == Config())
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aDeletedFileIsRestoredFromTheLastGoodCopyNotReset() throws {
        let url = tempFile(); defer { cleanUp(url) }
        try write(#"{"hotkey": "leftCommand"}"#, to: url, secondsAhead: -20)
        let store = ConfigStore(fileURL: url)
        _ = store.current()
        try FileManager.default.removeItem(at: url)
        #expect(store.current().hotkey == .leftCommand)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func savingFromInsideTheAppWorksAndSurvivesAReload() throws {
        let url = tempFile(); defer { cleanUp(url) }
        try write("{}", to: url, secondsAhead: -20)
        let store = ConfigStore(fileURL: url)
        #expect(store.update { $0.style = .exact } == true)
        #expect(ConfigStore(fileURL: url).current().style == .exact)
        #expect(!FileManager.default.fileExists(atPath: url.path + ".tmp"))
    }

    @Test func savingIsRefusedIfTheFileChangedSinceItWasRead() throws {
        let url = tempFile(); defer { cleanUp(url) }
        try write("{}", to: url, secondsAhead: -20)
        let store = ConfigStore(fileURL: url)
        var config = store.current()
        config.style = .polished
        // The owner edits the file in an editor between the read and the save.
        try write(#"{"hotkey": "leftCommand"}"#, to: url, secondsAhead: -5)
        let saved = store.update { c in
            try? write(#"{"hotkey": "rightControl"}"#, to: url, secondsAhead: -1)     // changes during the edit closure
            c.style = .polished
        }
        #expect(saved == false)
        #expect(try String(contentsOf: url, encoding: .utf8) == #"{"hotkey": "rightControl"}"#)
    }
}

@Suite("Last dictation")
struct LastDictationTests {
    func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("voice-it-history-\(UUID().uuidString)").appendingPathComponent("history.jsonl")
    }
    func cleanUp(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    @Test func historyIsOffByDefaultAndReadFromTheSettingsFile() throws {
        #expect(Config().history.enabled == false)
        #expect(try JSONDecoder().decode(Config.self, from: Data("{}".utf8)).history.enabled == false)
        #expect(try JSONDecoder().decode(Config.self, from: Data(#"{"history": {"enabled": true}}"#.utf8)).history.enabled == true)
    }

    @Test func memoryOnlyKeepsTheLastDictationAndWritesNothing() {
        let url = tempFile(); defer { cleanUp(url) }
        let store = LastDictationStore(fileURL: url)
        #expect(store.last(history: false) == nil)
        store.record(raw: "um hello", text: "Hello.", history: false)
        store.record(raw: "second raw", text: "Second.", history: false)
        #expect(store.last(history: false)?.text == "Second.")
        #expect(store.last(history: false)?.raw == "second raw")
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func memoryOnlyIsGoneAfterARestart() {
        let url = tempFile(); defer { cleanUp(url) }
        LastDictationStore(fileURL: url).record(raw: "a", text: "A", history: false)
        #expect(LastDictationStore(fileURL: url).last(history: false) == nil)     // a new store is a new launch
        #expect(LastDictationStore(fileURL: url).last(history: true) == nil)      // and nothing was written for history to read
    }

    @Test func historyOnSurvivesARestartAndKeepsEveryDictation() throws {
        let url = tempFile(); defer { cleanUp(url) }
        let store = LastDictationStore(fileURL: url)
        store.record(raw: "one raw", text: "One.", history: true)
        store.record(raw: "two raw", text: "Two.", history: true)
        let relaunched = LastDictationStore(fileURL: url)
        #expect(relaunched.last(history: true)?.text == "Two.")
        #expect(try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count == 2)
    }

    @Test func turningHistoryOffAfterwardsStopsReadingTheFileButLeavesIt() {
        let url = tempFile(); defer { cleanUp(url) }
        LastDictationStore(fileURL: url).record(raw: "r", text: "T", history: true)
        #expect(LastDictationStore(fileURL: url).last(history: false) == nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func emptyTextIsNotRecorded() {
        let url = tempFile(); defer { cleanUp(url) }
        let store = LastDictationStore(fileURL: url)
        store.record(raw: "", text: "", history: true)
        #expect(store.last(history: true) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func theHistoryFileIsReadableOnlyByTheOwner() throws {
        let url = tempFile(); defer { cleanUp(url) }
        LastDictationStore(fileURL: url).record(raw: "r", text: "T", history: true)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test func aDamagedLastLineFallsBackToTheLineBeforeIt() throws {
        let url = tempFile(); defer { cleanUp(url) }
        LastDictationStore(fileURL: url).record(raw: "r", text: "Good.", history: true)
        let handle = try FileHandle(forWritingTo: url); handle.seekToEndOfFile(); handle.write(Data("{ half a line".utf8)); try handle.close()
        #expect(LastDictationStore(fileURL: url).last(history: true)?.text == "Good.")
    }
}

@Suite("Menu status line")
struct MenuStatusTests {
    func decide(unsupported: String? = nil, settings: Bool = false, mic: Bool = false, input: Bool = false, failed: Bool = false, loading: Bool = false, setup: Bool = false) -> MenuStatus {
        MenuStatus.decide(unsupported: unsupported, settingsError: settings, microphoneOff: mic, inputMonitoringOff: input, modelFailed: failed, modelLoading: loading, setupNeeded: setup)
    }

    @Test func allWellIsReady() { #expect(decide() == .ready && decide().text == "Ready") }

    @Test func eachStateHasItsWords() {
        #expect(decide(loading: true).text == "Loading the model…")
        #expect(decide(mic: true).text == "Microphone access is off")
        #expect(decide(settings: true).text == "Settings error")
        #expect(decide(failed: true).text == "Couldn't load the speech model")
        #expect(decide(setup: true).text == "Setup needed")
    }

    @Test func theMostImportantProblemWins() {
        #expect(decide(unsupported: "Needs macOS 15 or later", settings: true, mic: true, loading: true) == .unsupported("Needs macOS 15 or later"))
        #expect(decide(settings: true, mic: true, loading: true) == .settingsError)
        #expect(decide(mic: true, input: true, loading: true, setup: true) == .setupNeeded)      // nothing else matters without the speech model
        #expect(decide(settings: true, setup: true) == .settingsError)
        #expect(decide(mic: true, input: true, loading: true) == .microphoneOff)
        #expect(decide(input: true, failed: true) == .inputMonitoringOff)
        #expect(decide(failed: true, loading: true) == .modelFailed)
    }
}

@Suite("Log file")
struct LogFileTests {
    func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("voice-it-log-\(UUID().uuidString)") }

    @Test func aFullLogBecomesTheOldOneAndAFreshOneStarts() throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = RotatingLogFile(url: dir.appendingPathComponent("a.log"), limit: 100)
        for i in 0..<10 { log.append("line \(i) ........................\n") }          // about 33 bytes each
        let now = try String(contentsOf: log.url, encoding: .utf8), before = try String(contentsOf: log.previousURL, encoding: .utf8)
        #expect(now.utf8.count <= 100 && before.utf8.count <= 100)
        #expect(now.contains("line 9") && before.contains("line "))
        #expect(!FileManager.default.fileExists(atPath: log.previousURL.appendingPathExtension("1").path))   // only one old file is kept
    }

    @Test func aLogAlreadyOverTheLimitIsRotatedOnTheFirstWrite() throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("a.log")
        try String(repeating: "x", count: 500).write(to: url, atomically: true, encoding: .utf8)
        let log = RotatingLogFile(url: url, limit: 100)
        log.append("fresh\n")
        #expect(try String(contentsOf: url, encoding: .utf8) == "fresh\n")
        #expect(try String(contentsOf: log.previousURL, encoding: .utf8).count == 500)
    }

    @Test func aSmallLogJustGrows() throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = RotatingLogFile(url: dir.appendingPathComponent("a.log"), limit: 1000)
        log.append("one\n"); log.append("two\n")
        #expect(try String(contentsOf: log.url, encoding: .utf8) == "one\ntwo\n")
        #expect(!FileManager.default.fileExists(atPath: log.previousURL.path))
    }
}

@Suite("Watching the settings folder")
struct ConfigWatchTests {
    @Test func savingTheFileIsNoticedWithoutPolling() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voice-it-watch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config.json")
        let store = ConfigStore(fileURL: file)
        _ = store.current()                                    // creates the folder and the defaults
        final class Box: @unchecked Sendable { var calls = 0 }
        let box = Box()
        store.onChange = { box.calls += 1 }
        store.startWatching()
        try #"{"style": "exact"}"#.write(to: file, atomically: true, encoding: .utf8)     // an editor's atomic save
        for _ in 0..<40 where box.calls == 0 { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(box.calls >= 1)
        #expect(store.current().style == .exact)
    }
}
