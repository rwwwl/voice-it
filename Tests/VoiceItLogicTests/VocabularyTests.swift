import Foundation
import Testing
@testable import VoiceItLogic

@Suite("Vocabulary")
struct VocabularyTests {
    typealias E = Config.DictionaryEntry
    let empty: [E] = []

    func add(_ heard: String?, _ correct: String, to e: [E]) throws -> [E] { try Vocabulary.adding(heard: heard, correct: correct, to: e) }
    func problem(_ heard: String?, _ correct: String, to e: [E]) -> VocabularyProblem? {
        do { _ = try add(heard, correct, to: e); return nil } catch { return error as? VocabularyProblem }
    }

    // MARK: Adding

    @Test func aCorrectionAndAPlainTermAreBothAdded() throws {
        var e = try add("fluid audio", "FluidAudio", to: empty)
        e = try add(nil, "Xcode", to: e)
        #expect(e == [E(term: "FluidAudio", heardAs: ["fluid audio"]), E(term: "Xcode", heardAs: [])])
        #expect(Vocabulary.rows(e).map(\.isCorrection) == [true, false])
    }

    @Test func emptyOrBlankHeardAsMeansAPlainTerm() throws {
        #expect(try add("", "Xcode", to: empty) == [E(term: "Xcode")])
        #expect(try add("   ", "Xcode", to: empty) == [E(term: "Xcode")])
    }

    @Test func spacesAreTidiedAround() throws {
        #expect(try add("  fluid   o  dio ", "  Fluid  Audio  ", to: empty) == [E(term: "Fluid Audio", heardAs: ["fluid o dio"])])
    }

    @Test func theCorrectSpellingCannotBeEmpty() {
        #expect(problem("x", "", to: empty) == .emptyCorrect)
        #expect(problem(nil, "   ", to: empty) == .emptyCorrect)
    }

    @Test func duplicatesAreCaseInsensitive() throws {
        let e = try add("fluid audio", "FluidAudio", to: empty)
        #expect(problem("Fluid Audio", "Something", to: e) == .duplicateHeard(heard: "Fluid Audio", term: "FluidAudio"))
        #expect(problem(nil, "fluidaudio", to: e) == .duplicateTerm(existing: "FluidAudio"))
        #expect(problem(nil, "FluidAudio", to: e) == .duplicateTerm(existing: "FluidAudio"))     // a plain term for a term already there
        let plain = try add(nil, "Xcode", to: empty)
        #expect(problem(nil, "XCODE", to: plain) == .duplicateTerm(existing: "Xcode"))
    }

    @Test func aSecondMishearingOfTheSameTermJoinsIt() throws {
        var e = try add("fluid audio", "FluidAudio", to: empty)
        e = try add("fluid o dio", "FluidAudio", to: e)
        #expect(e == [E(term: "FluidAudio", heardAs: ["fluid audio", "fluid o dio"])])
        #expect(Vocabulary.rows(e).count == 2)
    }

    @Test func aCorrectionWithTheSameCapitalisationOnlyMakesNoSense() {
        #expect(problem("xcode", "Xcode", to: empty) == .sameAsHeard)
    }

    @Test func overlongEntriesAreRefused() {
        #expect(problem(nil, String(repeating: "a", count: 81), to: empty) == .tooLong)
        #expect(problem(String(repeating: "a", count: 81), "b", to: empty) == .tooLong)
    }

    @Test func everyProblemHasAMessage() {
        let all: [VocabularyProblem] = [.emptyCorrect, .tooLong, .sameAsHeard, .duplicateTerm(existing: "A"), .duplicateHeard(heard: "a", term: "A"), .limitReached]
        #expect(all.allSatisfy { !$0.message.isEmpty })
        #expect(VocabularyProblem.limitReached.message.contains("\(Vocabulary.limit)"))
    }

    // MARK: The limit

    @Test func theListStopsAtTheLimit() throws {
        var e = empty
        for i in 0..<Vocabulary.limit { e = try add(nil, "Term\(i)", to: e) }
        #expect(Vocabulary.count(e) == Vocabulary.limit)
        #expect(problem(nil, "OneMore", to: e) == .limitReached)
        #expect(problem("heard it", "Term3", to: e) == .limitReached)         // a new mishearing is a new entry too
        #expect(Vocabulary.warnAt < Vocabulary.limit)
    }

    @Test func theCountIsOneForEveryRow() throws {
        var e = try add("a b", "AB", to: empty)
        e = try add("a bee", "AB", to: e)
        e = try add(nil, "Xcode", to: e)
        #expect(Vocabulary.count(e) == 3)
        #expect(Vocabulary.count(e) == Vocabulary.rows(e).count)
    }

    // MARK: Removing and editing

    @Test func removingARowRemovesOnlyThatRow() throws {
        var e = try add("fluid audio", "FluidAudio", to: empty)
        e = try add("fluid o dio", "FluidAudio", to: e)
        e = Vocabulary.removing(VocabularyRow(term: "FluidAudio", heard: "fluid audio"), from: e)
        #expect(e == [E(term: "FluidAudio", heardAs: ["fluid o dio"])])
        e = Vocabulary.removing(VocabularyRow(term: "FluidAudio", heard: "fluid o dio"), from: e)
        #expect(e.isEmpty)                                                      // the last row takes the term with it
        let plain = try add(nil, "Xcode", to: empty)
        #expect(Vocabulary.removing(VocabularyRow(term: "Xcode", heard: nil), from: plain).isEmpty)
    }

    @Test func removingSomethingNotThereChangesNothing() throws {
        let e = try add(nil, "Xcode", to: empty)
        #expect(Vocabulary.removing(VocabularyRow(term: "Nope", heard: nil), from: e) == e)
    }

    @Test func undoByAddingTheRowBackRestoresIt() throws {
        let e = try add("fluid audio", "FluidAudio", to: empty)
        let row = Vocabulary.rows(e)[0]
        let removed = Vocabulary.removing(row, from: e)
        #expect(try add(row.heard, row.term, to: removed) == e)
    }

    @Test func editingChangesTheRowAndAProblemChangesNothing() throws {
        var e = try add("fluid audio", "FluidAudio", to: empty)
        e = try add(nil, "Xcode", to: e)
        let row = VocabularyRow(term: "FluidAudio", heard: "fluid audio")
        let edited = try Vocabulary.replacing(row, heard: "fluid audio.", correct: "FluidAudio", in: e)
        #expect(Vocabulary.rows(edited).contains(VocabularyRow(term: "FluidAudio", heard: "fluid audio.")))
        #expect(throws: VocabularyProblem.self) { try Vocabulary.replacing(row, heard: "x", correct: "xcode", in: e) }      // would duplicate Xcode
        #expect(throws: VocabularyProblem.self) { try Vocabulary.replacing(row, heard: "x", correct: "", in: e) }
    }

    @Test func aRowCanBeEditedToItselfAtTheLimit() throws {
        var e = empty
        for i in 0..<Vocabulary.limit { e = try add(nil, "Term\(i)", to: e) }
        #expect(try Vocabulary.replacing(VocabularyRow(term: "Term5", heard: nil), heard: nil, correct: "Term5", in: e) == e.filter { $0.term != "Term5" } + [E(term: "Term5")])
    }

    // MARK: Add many

    @Test func addManyReadsEqualsAndArrowsAndPlainLines() {
        let text = """
        fluid audio = FluidAudio
        para keet -> Parakeet
        swift ui → SwiftUI
        a b => AB

        Xcode
        """
        let r = Vocabulary.addingMany(text, to: [])
        #expect(r.added == 5 && r.skipped.isEmpty)
        #expect(r.summary == "Added 5, skipped 0.")
        #expect(Vocabulary.rows(r.entries).count == 5)
    }

    @Test func addManyReportsWhatItSkippedAndWhy() {
        let text = "fluid audio = FluidAudio\nFluidAudio\nfluid audio = Other\nbad =\nokay = OK"
        let r = Vocabulary.addingMany(text, to: [])
        #expect(r.added == 2)                                          // the first line and "okay = OK"
        #expect(r.skipped.map(\.line) == [2, 3, 4])
        #expect(r.skipped[0].reason.contains("in the list"))
        #expect(r.skipped[1].reason.contains("already corrected"))
        #expect(r.skipped[2].reason.contains("can't be empty"))
    }

    @Test func addManyStopsAtTheLimitAndSaysSo() {
        let text = (0..<(Vocabulary.limit + 3)).map { "Term\($0)" }.joined(separator: "\n")
        let r = Vocabulary.addingMany(text, to: [])
        #expect(r.added == Vocabulary.limit && r.skipped.count == 3)
        #expect(r.skipped.allSatisfy { $0.reason.contains("full") })
    }

    // MARK: Copy list and search

    @Test func theListCopiesAsTextThatAddManyCanReadBack() throws {
        var e = try add("fluid audio", "FluidAudio", to: empty)
        e = try add(nil, "Xcode", to: e)
        let text = Vocabulary.listText(e)
        #expect(text == "fluid audio = FluidAudio\nXcode")
        #expect(Vocabulary.addingMany(text, to: []).entries.count == 2)
    }

    @Test func searchLooksInBothColumnsIgnoringCase() {
        let row = VocabularyRow(term: "FluidAudio", heard: "fluid audio")
        #expect(Vocabulary.matches(row, search: "AUDIO") && Vocabulary.matches(row, search: "fluid") && Vocabulary.matches(row, search: ""))
        #expect(!Vocabulary.matches(row, search: "parakeet"))
        #expect(Vocabulary.matches(VocabularyRow(term: "Xcode", heard: nil), search: "xcode"))
    }

    @Test func rowsAreSortedAndStable() throws {
        let e = [E(term: "banana"), E(term: "Apple", heardAs: ["a pull"]), E(term: "cherry")]
        #expect(Vocabulary.rows(e).map(\.term) == ["Apple", "banana", "cherry"])
    }
}
