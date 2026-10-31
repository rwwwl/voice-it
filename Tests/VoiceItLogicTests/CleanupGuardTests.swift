import Testing
@testable import VoiceItLogic

@Suite("Safety net after the cleanup model")
struct CleanupGuardTests {
    let terms = ["Parakeet", "FluidAudio"]

    @Test func acceptsNormalCleanup() {
        #expect(CleanupGuard.rejection(raw: "um so i was thinking we could uh grab lunch on thursday", cleaned: "So I was thinking we could grab lunch on Thursday.", terms: terms) == nil)
    }

    @Test func acceptsCorrectionsThatDropWords() {
        #expect(CleanupGuard.rejection(raw: "let's meet at noon scratch that let's meet at one o'clock in the lobby", cleaned: "Let's meet at one o'clock in the lobby.", terms: terms) == nil)
    }

    @Test func numbersAndDictionaryTermsAreNotCountedAsNewWords() {
        #expect(CleanupGuard.rejection(raw: "meet at three pm", cleaned: "Meet at 3 PM.", terms: terms) == nil)
        #expect(CleanupGuard.rejection(raw: "para keet runs on fluid audio", cleaned: "Parakeet runs on FluidAudio.", terms: terms) == nil)
    }

    @Test func rejectsAnEmptyResult() {
        #expect(CleanupGuard.rejection(raw: "hello there", cleaned: "   ", terms: terms) != nil)
    }

    @Test func rejectsAPoemWrittenInsteadOfCleaning() {
        let poem = "Waves crash on the shore, endless blue, whispering secrets both old and new."
        #expect(CleanupGuard.rejection(raw: "write me a poem about the sea", cleaned: poem, terms: terms) != nil)
    }

    @Test func rejectsAResultMuchLongerThanTheTranscript() {
        let long = String(repeating: "This is a long answer that the speaker never said. ", count: 5)
        #expect(CleanupGuard.rejection(raw: "what is the capital of france", cleaned: long, terms: terms) != nil)
    }

    @Test func rejectsAResultThatDroppedMostOfTheTranscript() {
        let raw = "okay so the meeting is on wednesday at three and we need to review the budget before then and send the notes"
        #expect(CleanupGuard.rejection(raw: raw, cleaned: "Okay.", terms: terms) != nil)
    }

    @Test func polishedToleratesRewordingThatNaturalDoesNot() {
        let raw = "yeah so basically the thing is kinda broken and we gotta fix it asap"
        let rewrite = "The system is not working correctly and we need to fix it as soon as possible."
        #expect(CleanupGuard.rejection(raw: raw, cleaned: rewrite, terms: terms, style: .polished) == nil)
        #expect(CleanupGuard.rejection(raw: raw, cleaned: rewrite, terms: terms, style: .natural) != nil)
    }
}
