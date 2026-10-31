import Foundation
import Testing
@testable import VoiceItLogic

@Suite("What the rules do to the text")
struct RulesTextTests {
    func config() -> Config {
        var c = Config()
        c.dictionary = Config.exampleDictionary
        c.snippets = [Config.Snippet(trigger: "my email address", expansion: "hello@example.com")]
        return c
    }
    let heard = "um hi sam new line ask para keet at my email address question mark"

    @Test func theRulesRemoveFillersAndApplyDictionarySnippetsAndSpokenFormattingWithoutAModel() {
        #expect(TextProcessing.withoutModel(heard, config: config()) == "hi sam\nAsk Parakeet at hello@example.com?")
    }

    @Test func theRulesAreTheSameWhetherOrNotTheModelRunsAfterThem() {
        let c = config()
        #expect(TextProcessing.prepare(heard, config: c).raw == TextProcessing.withoutModel(heard, config: c))
    }
}

@Suite("Filler words")
struct FillerTests {
    func clean(_ s: String) -> String { TextProcessing.removeFillers(s) }

    @Test func theFiveFillersAreRemovedWhereverTheyAre() {
        #expect(clean("So um I think so") == "So I think so")
        #expect(clean("I was uh going to go") == "I was going to go")
        #expect(clean("It is er complicated") == "It is complicated")
        #expect(clean("It is erm complicated") == "It is complicated")
        #expect(clean("Ah that works") == "That works")
    }

    @Test func stretchedAndShoutedFillersAreCaughtToo() {
        #expect(clean("It was ummm fine") == "It was fine")
        #expect(clean("It was UHHH fine") == "It was fine")
    }

    @Test func theCommasAroundAFillerGoWithIt() {
        #expect(clean("Um, I think so.") == "I think so.")
        #expect(clean("So, um, I think so.") == "So, I think so.")
        #expect(clean("I think, um, that works.") == "I think, that works.")
        #expect(clean("That is, um I mean fine") == "That is I mean fine")
    }

    @Test func aSentenceThatStartedWithAFillerStillStartsWithACapital() {
        #expect(clean("Done. Um, next steps.") == "Done. Next steps.")
        #expect(clean("Uh, what time is it?") == "What time is it?")
    }

    @Test func youKnowAndLikeAreLeftAlone() {
        #expect(clean("You know, I like it") == "You know, I like it")
        #expect(clean("It is like a river") == "It is like a river")
    }

    @Test func partsOfOtherWordsAndHyphenatedWordsAreLeftAlone() {
        #expect(clean("The human error umbrella") == "The human error umbrella")
        #expect(clean("He said uh-huh and ah-ha") == "He said uh-huh and ah-ha")
        #expect(clean("Her answer was herm") == "Her answer was herm")
    }

    @Test func textWithoutFillersIsUnchanged() {
        #expect(clean("Nothing to remove here.") == "Nothing to remove here.")
        #expect(clean("") == "")
    }

    @Test func aFillerOnItsOwnLeavesNothing() {
        #expect(clean("Um") == "")
        #expect(clean("Um, uh") == "")
    }
}

@Suite("Saving settings from the app")
struct ConfigStoreTests {
    func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("voice-it-config-\(UUID().uuidString)").appendingPathComponent("config.json")
    }
    func cleanUp(_ file: URL) { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

    @Test func aMissingFileIsCreatedWithTheDefaults() {
        let file = tempFile(); defer { cleanUp(file) }
        let store = ConfigStore(fileURL: file)
        #expect(store.current().style == .natural)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func changingTheStyleIsSavedAndSurvivesARestart() {
        let file = tempFile(); defer { cleanUp(file) }
        let store = ConfigStore(fileURL: file)
        #expect(store.update { $0.style = .exact })
        #expect(store.current().style == .exact)
        #expect(ConfigStore(fileURL: file).current().style == .exact)      // a fresh store reads it from the file
    }

    @Test func savingTheSameValueWritesNothing() {
        let file = tempFile(); defer { cleanUp(file) }
        let store = ConfigStore(fileURL: file)
        _ = store.current()
        #expect(!store.update { $0.style = .natural })                             // already full
        #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().appendingPathComponent("config.json.bak").path))
    }

    @Test func theFirstSaveKeepsABackupOfTheFileAsItWas() throws {
        let file = tempFile(); defer { cleanUp(file) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"cleanup": {"mode": "full"}, "myOwnNote": "keep me"}"#.write(to: file, atomically: true, encoding: .utf8)
        let store = ConfigStore(fileURL: file)
        #expect(store.update { $0.style = .exact })
        let backup = file.deletingLastPathComponent().appendingPathComponent("config.json.bak")
        #expect(try String(contentsOf: backup, encoding: .utf8).contains("myOwnNote"))      // the original survives in the backup
        #expect(!(try String(contentsOf: file, encoding: .utf8)).contains("myOwnNote"))     // unknown keys don't survive the rewrite
        #expect(store.update { $0.style = .natural })                                   // a second save must not replace the backup
        #expect(try String(contentsOf: backup, encoding: .utf8).contains("myOwnNote"))
    }
}
