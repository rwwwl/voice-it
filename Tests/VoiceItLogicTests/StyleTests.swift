import Foundation
import Testing
@testable import VoiceItLogic

@Suite("Style settings")
struct StyleSettingsTests {
    func decode(_ json: String) throws -> Config { try JSONDecoder().decode(Config.self, from: Data(json.utf8)) }
    func problem(_ json: String) -> ConfigProblem? {
        do { _ = try decode(json); return nil } catch { return ConfigProblem.diagnose(error, in: Data(json.utf8)) }
    }

    @Test func theDefaultsAreNaturalAndKeepReady() throws {
        let c = try decode("{}")
        #expect(c.style == .natural && c.cleanup.memory == .keepReady && c.cleanup.idleMinutes == 10 && c.cleanup.naturalLongTextWords == 30)
    }

    @Test func everyChoiceIsReadInAnyCase() throws {
        for (name, choice) in [("exact", StyleChoice.exact), ("Natural", .natural), ("POLISHED", .polished), ("automatic", .automatic), ("Automatic by app", .automatic)] {
            #expect(try decode(#"{"style": "\#(name)"}"#).style == choice)
        }
        #expect(try decode(#"{"cleanup": {"memory": "freeWhenIdle"}}"#).cleanup.memory == .freeWhenIdle)
        #expect(try decode(#"{"cleanup": {"memory": "keep ready"}}"#).cleanup.memory == .keepReady)
    }

    @Test func anUnknownStyleIsASettingsErrorThatNamesTheChoices() {
        let json = "{\n  \"style\": \"fancy\"\n}"
        let p = problem(json)
        #expect(p?.line == 2)
        #expect(p?.message.contains("unknown style \"fancy\"") == true && p?.message.contains("exact, natural, polished, automatic") == true)
    }

    @Test func theOldLiteralToneIsNotAStyle() {
        #expect(problem(#"{"style": "literal"}"#) != nil)
        #expect(problem(#"{"appStyles": {"com.apple.Terminal": "literal"}}"#) != nil)
    }

    @Test func theOldModeAndToneKeysAreSimplyNotRead() throws {
        // No migration: a file from before styles still loads. Its old keys do nothing and the new defaults apply.
        let c = try decode(#"{"cleanup": {"mode": "off", "model": "kept"}, "defaultTone": "wild", "tones": {"com.apple.mail": "formal"}}"#)
        #expect(c.style == .natural && c.cleanup.model == "kept")
        #expect(c.effectiveStyle(forApp: "com.apple.mail") == .natural)
    }

    @Test func aBadAppStyleNamesTheApp() {
        let p = problem(#"{"appStyles": {"com.apple.mail": "fancy"}}"#)
        #expect(p?.message.contains("appStyles.com.apple.mail") == true)
    }

    @Test func aBadMemorySettingIsAnError() {
        #expect(problem(#"{"cleanup": {"memory": "sometimes"}}"#)?.message.contains("keepReady, freeWhenIdle") == true)
    }

    @Test func theNumbersHaveRanges() throws {
        #expect(try decode(#"{"cleanup": {"idleMinutes": 240, "naturalLongTextWords": 10}}"#).cleanup.idleMinutes == 240)
        #expect(problem(#"{"cleanup": {"idleMinutes": 0}}"#)?.message.contains("from 1 to 240") == true)
        #expect(problem(#"{"cleanup": {"idleMinutes": 241}}"#) != nil)
        #expect(problem(#"{"cleanup": {"naturalLongTextWords": 9}}"#)?.message.contains("from 10 to 200") == true)
        #expect(problem(#"{"cleanup": {"naturalLongTextWords": "many"}}"#) != nil)
    }

    @Test func settingsSurviveASaveAndReload() throws {
        var c = Config(); c.style = .automatic; c.cleanup.memory = .freeWhenIdle; c.cleanup.idleMinutes = 3; c.cleanup.naturalLongTextWords = 45
        c.appStyles = ["com.example.app": .polished]
        #expect(try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c)) == c)
    }

    @Test func aFixedStyleIgnoresTheAppList() {
        var c = Config()
        for (choice, style) in [(StyleChoice.exact, Style.exact), (.natural, .natural), (.polished, .polished)] {
            c.style = choice
            #expect(c.effectiveStyle(forApp: "com.apple.mail") == style && c.effectiveStyle(forApp: nil) == style)
        }
    }

    @Test func automaticUsesTheAppListAndNaturalForEverythingElse() {
        var c = Config(); c.style = .automatic
        #expect(c.effectiveStyle(forApp: "com.apple.mail") == .polished)
        #expect(c.effectiveStyle(forApp: "com.apple.Terminal") == .exact)
        #expect(c.effectiveStyle(forApp: "com.unknown.app") == .natural)
        #expect(c.effectiveStyle(forApp: nil) == .natural)
    }
}

@Suite("Natural style: when the model is used")
struct NaturalPolicyTests {
    func reason(_ s: String, words: Int = 30) -> NaturalPolicy.Reason? { NaturalPolicy.reason(for: s, longTextWords: words) }

    @Test func shortCleanTextDoesNotUseTheModel() {
        for s in ["Hello there.", "Can you send me the latest draft when you get a chance?", "I'll be there at five.", "No problem at all.",
                  "There is no idea what happened.", "Thanks, see you Friday.", ""] {
            #expect(reason(s) == nil, "\(s)")
        }
    }

    @Test func correctionCuesAreCaught() {
        for s in ["Meet at three, actually four.", "Send it Tuesday, I mean Wednesday.", "I meant the other one.", "Sorry, the red one.",
                  "Call him, wait, call her.", "Book it, scratch that.", "Make that two tickets.", "Never mind the last bit.", "Nevermind.",
                  "Friday, or rather Saturday.", "Let me rephrase that."] {
            #expect(reason(s) == .correctionCue, "\(s)")
        }
    }

    @Test func noIsACueUnlessItIsPartOfAnIdiom() {
        for s in ["No, I think it was Friday.", "Tuesday, no wait, Wednesday.", "Tuesday no I mean Wednesday", "Send it, no make it tomorrow.",
                  "the meeting is on tuesday no wednesday at three", "I want the large no the small coffee", "No."] {
            #expect(reason(s) == .correctionCue, "\(s)")
        }
        for s in ["No problem.", "I have no idea.", "Nothing to add.", "There are no more.", "No worries at all.", "It makes no difference.", "We have no one free."] {
            #expect(reason(s) == nil, "\(s)")
        }
    }

    @Test func repeatedWordsAndPhrasesAreCaught() {
        #expect(reason("Send me the the latest draft.") == .repeatedWords)
        #expect(reason("Can you can you send it?") == .repeatedWords)
        #expect(reason("Send it to him to him tomorrow.") == .repeatedWords)
        #expect(reason("So what time does the the shop open?") == .repeatedWords)
    }

    @Test func properRepeatsAreNotTriggers() {
        #expect(reason("I think he had had enough.") == nil)
        #expect(reason("I know that that is odd.") == nil)
        #expect(reason("Call 555 555 for details.") == nil)
    }

    @Test func fillerPhrasesAreCaught() {
        for s in ["We could, you know, grab lunch.", "It is kind of late.", "It was sort of fine.", "Grab a coffee or something.",
                  "Pizza or whatever works.", "It is basically done."] {
            #expect(reason(s) == .fillerPhrase, "\(s)")
        }
    }

    @Test func lengthIsAnExactBoundary() {
        func text(_ n: Int) -> String { (1...n).map { "word\($0)" }.joined(separator: " ") }
        #expect(reason(text(29)) == nil)
        #expect(reason(text(30)) == nil)
        #expect(reason(text(31)) == .long)
        #expect(reason(text(11), words: 10) == .long)
        #expect(reason(text(10), words: 10) == nil)
    }

    @Test func aCueBeatsLengthAndTheLabelNamesOnlyTheKind() {
        let long = (1...40).map { "w\($0)" }.joined(separator: " ") + " actually"
        #expect(reason(long) == .correctionCue)
        #expect(NaturalPolicy.Reason.long.label == "long text" && NaturalPolicy.Reason.correctionCue.label == "correction cue")
    }

    @Test func curlyApostrophesAndCaseDoNotMatter() {
        #expect(reason("WAIT, I didn’t mean that.") == .correctionCue)
        #expect(reason("It’s fine, it’s fine.") == .repeatedWords)
    }
}

@Suite("Model plan")
struct ModelPlanTests {
    let loaded = ModelPlan.ModelState(installed: true, loaded: true)
    let notLoaded = ModelPlan.ModelState(installed: true, loaded: false)
    let loading = ModelPlan.ModelState(installed: true, loaded: false, loading: true)
    let missing = ModelPlan.ModelState(installed: false, loaded: false)
    func decide(_ style: Style, _ text: String, _ model: ModelPlan.ModelState) -> ModelPlan.Decision {
        ModelPlan.decide(style: style, text: text, longTextWords: 30, model: model)
    }

    @Test func exactNeverUsesTheModel() {
        for model in [loaded, notLoaded, loading, missing] { #expect(decide(.exact, "Meet at three, actually four.", model) == .skip(.exactStyle)) }
    }

    @Test func nothingUsesAModelThatIsNotInstalled() {
        #expect(decide(.natural, "Meet at three, actually four.", missing) == .skip(.notInstalled))
        #expect(decide(.polished, "Hello.", missing) == .skip(.notInstalled))
    }

    @Test func polishedAlwaysUsesTheModel() {
        #expect(decide(.polished, "Hello.", loaded) == .use(.polished))
        #expect(decide(.polished, "Hello.", notLoaded) == .loadThenUse(.polished))
        #expect(decide(.polished, "Hello.", loading) == .loadThenUse(.polished))
    }

    @Test func naturalSkipsCleanTextEvenWhenTheModelIsReady() {
        #expect(decide(.natural, "Thanks, see you Friday.", loaded) == .skip(.cleanText))
        #expect(decide(.natural, "Thanks, see you Friday.", notLoaded) == .skip(.cleanText))
    }

    @Test func naturalUsesTheModelWhenATriggerIsFound() {
        #expect(decide(.natural, "Meet at three, actually four.", loaded) == .use(.natural(.correctionCue)))
        #expect(decide(.natural, "Meet at three, actually four.", notLoaded) == .loadThenUse(.natural(.correctionCue)))
    }

    @Test func theLogLabelsNameTheKindOfReasonOnly() {
        #expect(decide(.natural, "Thanks.", loaded).label == "model skipped (short clean text)")
        #expect(decide(.natural, "Send it, actually no.", loaded).label == "model used (correction cue)")
        #expect(decide(.polished, "Hi.", loaded).label == "model used (polished style)")
        #expect(decide(.exact, "Hi.", loaded).label == "model skipped (exact style)")
    }

    @Test func onlyPolishedWithFreeWhenIdleLoadsAtKeyDown() {
        #expect(ModelPlan.loadAtKeyDown(style: .polished, memory: .freeWhenIdle, model: notLoaded))
        #expect(!ModelPlan.loadAtKeyDown(style: .polished, memory: .freeWhenIdle, model: loaded))
        #expect(!ModelPlan.loadAtKeyDown(style: .polished, memory: .freeWhenIdle, model: loading))
        #expect(!ModelPlan.loadAtKeyDown(style: .polished, memory: .freeWhenIdle, model: missing))
        #expect(!ModelPlan.loadAtKeyDown(style: .natural, memory: .freeWhenIdle, model: notLoaded))
        #expect(!ModelPlan.loadAtKeyDown(style: .polished, memory: .keepReady, model: notLoaded))
    }

    @Test func keepReadyLoadsAndExactFreesWhenSettingsChange() {
        typealias P = ModelPlan
        #expect(P.settingsAction(choice: .natural, memory: .keepReady, model: notLoaded) == .load)
        #expect(P.settingsAction(choice: .automatic, memory: .keepReady, model: notLoaded) == .load)
        #expect(P.settingsAction(choice: .natural, memory: .keepReady, model: loaded) == .none)
        #expect(P.settingsAction(choice: .natural, memory: .keepReady, model: loading) == .none)
        #expect(P.settingsAction(choice: .exact, memory: .keepReady, model: loaded) == .unload)
        #expect(P.settingsAction(choice: .exact, memory: .freeWhenIdle, model: loading) == .unload)
        #expect(P.settingsAction(choice: .exact, memory: .keepReady, model: notLoaded) == .none)
        #expect(P.settingsAction(choice: .natural, memory: .freeWhenIdle, model: notLoaded) == .none)
        #expect(P.settingsAction(choice: .polished, memory: .keepReady, model: missing) == .none)
    }

    @Test func theModelIsFreedOnlyAfterTheIdleTime() {
        typealias P = ModelPlan
        #expect(!P.shouldFreeForIdle(memory: .freeWhenIdle, idleMinutes: 10, lastUsed: 0, now: 599, loaded: true))
        #expect(P.shouldFreeForIdle(memory: .freeWhenIdle, idleMinutes: 10, lastUsed: 0, now: 600, loaded: true))
        #expect(!P.shouldFreeForIdle(memory: .freeWhenIdle, idleMinutes: 10, lastUsed: 0, now: 6000, loaded: false))
        #expect(!P.shouldFreeForIdle(memory: .keepReady, idleMinutes: 10, lastUsed: 0, now: 6000, loaded: true))
        #expect(!P.shouldFreeForIdle(memory: .freeWhenIdle, idleMinutes: 10, lastUsed: nil, now: 6000, loaded: true))
    }
}

@Suite("Styles that may use the model")
struct StylesThatMayUseModelTests {
    @Test func aFixedStyleGivesJustItselfAndExactGivesNone() {
        var c = Config()
        for (choice, expected) in [(StyleChoice.exact, [Style]()), (.natural, [.natural]), (.polished, [.polished])] {
            c.style = choice
            #expect(c.stylesThatMayUseModel == expected)
        }
    }

    @Test func automaticGivesTheNonExactStylesOfTheAppListPlusNatural() {
        var c = Config(); c.style = .automatic
        #expect(c.stylesThatMayUseModel == [.natural, .polished])
        c.appStyles = ["com.apple.Terminal": .exact]
        #expect(c.stylesThatMayUseModel == [.natural])                       // unlisted apps still use Natural
        c.appStyles = ["com.apple.mail": .polished]
        #expect(c.stylesThatMayUseModel == [.natural, .polished])
    }
}

@Suite("Speech model warm-up")
struct SpeechWarmUpTests {
    @Test func warmsAfterAPauseAndBeforeTheFirstUse() {
        #expect(SpeechWarmUp.shouldWarm(lastUse: nil, now: 100))
        #expect(SpeechWarmUp.shouldWarm(lastUse: 100, now: 105))
        #expect(SpeechWarmUp.shouldWarm(lastUse: 0, now: 3600))
    }

    @Test func doesNotWarmWhileTheModelIsStillAwake() {
        #expect(!SpeechWarmUp.shouldWarm(lastUse: 100, now: 100))
        #expect(!SpeechWarmUp.shouldWarm(lastUse: 100, now: 104.9))
    }
}

@Suite("Natural policy against the cleanup samples")
struct NaturalPolicyFixtureTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("fixtures/cleanup")

    static let config: Config = { var c = Config(); c.dictionary = Config.exampleDictionary; return c }()

    /// Samples where the model changes the words but no rule can tell from the text: a mishearing that is not in the dictionary.
    static let knownMisses: Set<String> = ["20-dictionary-multi.natural"]

    @Test func theModelIsCalledForEverySampleWhoseWordsItChangesExceptTheKnownMisses() throws {
        let baseline = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: Self.folder.appendingPathComponent("baseline.json")))
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.folder.path).filter { $0.hasSuffix(".natural.raw.txt") }.sorted()
        #expect(names.count >= 10)
        var missed: [String] = [], needed = 0, skipped = 0
        for file in names {
            let name = String(file.dropLast(".raw.txt".count))
            let raw = try String(contentsOf: Self.folder.appendingPathComponent(file), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let rules = TextProcessing.prepare(raw, config: Self.config).raw
            let cleaned = try #require(baseline[name])
            let reason = NaturalPolicy.reason(for: rules, longTextWords: 30)
            if reason == nil { skipped += 1 }
            if NaturalPolicy.tokens(cleaned) != NaturalPolicy.tokens(rules) {
                needed += 1
                if reason == nil && !Self.knownMisses.contains(name) { missed.append(name) }
            }
        }
        #expect(missed.isEmpty, "the policy skipped the model where it changes the words: \(missed)")
        #expect(needed > 0 && skipped > 0)          // the samples really exercise both outcomes
    }

    @Test func theKnownMissesStillAreMisses() throws {
        // If a rule is added that catches one, take it off the list rather than let the list go stale.
        for name in Self.knownMisses {
            let raw = try String(contentsOf: Self.folder.appendingPathComponent(name + ".raw.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(NaturalPolicy.reason(for: TextProcessing.prepare(raw, config: Self.config).raw, longTextWords: 30) == nil, "\(name)")
        }
    }
}
