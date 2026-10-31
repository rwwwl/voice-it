import Testing
@testable import VoiceItLogic

@Suite("Dictionary, snippets and spoken formatting")
struct TextProcessingTests {
    func config(snippets: [Config.Snippet] = []) -> Config {
        var c = Config()
        c.dictionary = Config.exampleDictionary
        c.snippets = snippets
        return c
    }

    @Test func textWithNoCommandsPassesThroughUnchanged() {
        let p = TextProcessing.prepare("we should ship it on monday", config: config())
        #expect(p.forModel == "we should ship it on monday")
        #expect(p.raw == "we should ship it on monday")
        #expect(p.restore("We should ship it on Monday.") == "We should ship it on Monday.")
    }

    @Test func knownMishearingsAreReplacedBeforeTheModel() {
        let p = TextProcessing.prepare("ask para keet to use fluid audio on the neural engine", config: config())
        #expect(p.forModel == "ask Parakeet to use FluidAudio on the Neural Engine")
    }

    @Test func mishearingsMatchWholeWordsAnyCase() {
        let p = TextProcessing.prepare("Fluid Audio and fluid audios", config: config())
        #expect(p.forModel == "FluidAudio and fluid audios")   // "audios" is not the whole word
    }

    @Test func dictionarySpellingIsRestoredAfterTheModelLowercasesIt() {
        let p = TextProcessing.prepare("hello", config: config())
        #expect(p.restore("So I asked parakeet to run on the neural engine.") == "So I asked Parakeet to run on the Neural Engine.")
    }

    @Test func snippetsBecomePlaceholdersAndComeBack() {
        let snippet = Config.Snippet(trigger: "my email address", expansion: "hello@example.com")
        let p = TextProcessing.prepare("please send it to my email address today", config: config(snippets: [snippet]))
        #expect(p.forModel == "please send it to ZZ1ZZ today")
        #expect(p.raw == "please send it to hello@example.com today")
        #expect(p.restore("Please send it to ZZ1ZZ today.") == "Please send it to hello@example.com today.")
    }

    @Test func aModelThatLosesOrDuplicatesAPlaceholderIsRejected() {
        let snippet = Config.Snippet(trigger: "my email address", expansion: "hello@example.com")
        let p = TextProcessing.prepare("send it to my email address", config: config(snippets: [snippet]))
        #expect(p.restore("Send it to [1].") == nil)                // mangled
        #expect(p.restore("Send it to.") == nil)                    // dropped
        #expect(p.restore("Send it to ZZ1ZZ ZZ1ZZ.") == nil)        // duplicated
    }

    @Test func newLineAndNewParagraphBecomeLineBreaks() {
        let p = TextProcessing.prepare("hi sam new line thanks for the update new paragraph can we talk", config: config())
        #expect(p.raw == "hi sam\nThanks for the update\n\nCan we talk")
    }

    @Test func strayPunctuationAndSpacesNextToABreakAreRemovedAfterCleanup() {
        let p = TextProcessing.prepare("hi sam new line thanks", config: config())
        // The model often adds a comma or space next to the placeholder.
        #expect(p.restore("Hi Sam ZZ1ZZ, thanks.") == "Hi Sam\nThanks.")
    }

    @Test func spokenPunctuationAttachesToThePreviousWord() {
        let a = TextProcessing.prepare("can we talk tomorrow question mark", config: config())
        #expect(a.forModel == "can we talk tomorrow?")
        let b = TextProcessing.prepare("is it ready, question mark", config: config())
        #expect(b.forModel == "is it ready?")
        let c = TextProcessing.prepare("that is great exclamation mark", config: config())
        #expect(c.forModel == "that is great!")
    }
}
