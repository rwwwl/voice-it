import Foundation
import Testing
@testable import VoiceItLogic

@Suite("Long dictations are split for the cleanup model")
struct TextChunkerTests {
    @Test func shortTextIsOnePiece() {
        #expect(TextChunker.split("Hello there. How are you?") == ["Hello there. How are you?"])
        #expect(TextChunker.split("") == [""])
    }

    @Test func longTextIsSplitAtSentenceEndsIntoPiecesOfAboutTheTargetSize() {
        let sentence = "This is a fairly ordinary sentence about nothing in particular."
        let text = Array(repeating: sentence, count: 30).joined(separator: " ")
        let pieces = TextChunker.split(text)
        #expect(pieces.count > 3)
        #expect(pieces.allSatisfy { $0.count <= TextChunker.pieceSize + 10 && $0.hasSuffix(".") })
    }

    @Test func nothingIsLostAndNothingIsAdded() {
        let sentence = "Another sentence goes here, with a comma and some words."
        let text = Array(repeating: sentence, count: 25).joined(separator: " ")
        #expect(TextChunker.split(text).joined(separator: " ") == text)
    }

    @Test func aWallOfTextWithNoPunctuationIsStillCutAtSpaces() {
        let text = Array(repeating: "word", count: 600).joined(separator: " ")
        let pieces = TextChunker.split(text)
        #expect(pieces.count > 1)
        #expect(pieces.allSatisfy { $0.count <= TextChunker.pieceSize * 2 })
        #expect(pieces.joined(separator: " ") == text)
    }

    @Test func placeholdersStayWholeBecauseTheyContainNoSpacesOrSentenceEnds() {
        let text = Array(repeating: "Some words then ZZ1ZZ and more words follow here.", count: 20).joined(separator: " ")
        #expect(TextChunker.split(text).joined(separator: " ").components(separatedBy: "ZZ1ZZ").count == 21)
    }
}
