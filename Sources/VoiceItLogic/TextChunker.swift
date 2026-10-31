import Foundation

/// Splits long dictations into pieces for the cleanup model, which gets slower with length. Pieces end at sentence ends where
/// possible, so each one can be cleaned on its own and the results joined. Short text is returned whole.
public enum TextChunker {
    /// Text up to this many characters goes to the model in one piece.
    public static let wholeLimit = 500
    /// Target size of a piece (about 100 tokens) once the text is split.
    public static let pieceSize = 400

    public static func split(_ text: String, wholeLimit: Int = TextChunker.wholeLimit, pieceSize: Int = TextChunker.pieceSize) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > wholeLimit else { return [text] }
        // Sentences: break after . ! ? when whitespace follows.
        var sentences: [String] = []
        var current = ""
        let chars = Array(trimmed)
        for (i, ch) in chars.enumerated() {
            current.append(ch)
            if ".!?".contains(ch), i + 1 < chars.count, chars[i + 1].isWhitespace { sentences.append(current); current = "" }
        }
        if !current.isEmpty { sentences.append(current) }
        // A sentence with no punctuation that is far too long is cut at a space.
        var units: [String] = []
        for s in sentences {
            var rest = s.trimmingCharacters(in: .whitespaces)
            while rest.count > pieceSize * 2 {
                let limit = rest.index(rest.startIndex, offsetBy: pieceSize)
                let cut = rest[..<limit].lastIndex(of: " ") ?? limit
                units.append(String(rest[..<cut]))
                rest = String(rest[cut...]).trimmingCharacters(in: .whitespaces)
            }
            if !rest.isEmpty { units.append(rest) }
        }
        // Group sentences up to the piece size.
        var pieces: [String] = []
        var piece = ""
        for u in units {
            if !piece.isEmpty, piece.count + 1 + u.count > pieceSize { pieces.append(piece); piece = u }
            else { piece = piece.isEmpty ? u : piece + " " + u }
        }
        if !piece.isEmpty { pieces.append(piece) }
        return pieces
    }
}
