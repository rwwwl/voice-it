import Foundation

/// A safety net after the model: if the "cleaned" text isn't recognisably the same words as the transcript
/// (the model answered a question, wrote a poem, or went on and on), it is thrown away and the raw text is pasted instead.
public enum CleanupGuard {
    /// Returns nil if the cleaned text is acceptable, or the reason it was rejected.
    public static func rejection(raw: String, cleaned: String, terms: [String], style: Style = .natural) -> String? {
        let cleanedWords = words(cleaned), rawWords = words(raw)
        if cleanedWords.isEmpty { return "empty result" }
        if cleaned.count > raw.count * 3 / 2 + 20 { return "result much longer than the transcript" }
        if cleanedWords.count * 10 < rawWords.count * 3 { return "result dropped most of the transcript" }
        // Words that weren't in the transcript or the dictionary (numbers excepted: "three" can become "3").
        let known = Set(rawWords).union(terms.flatMap { words($0) })
        let unknown = cleanedWords.filter { w in !known.contains(w) && !w.contains(where: \.isNumber) }
        // Polished rewrites informal wording, so it legitimately uses words that weren't said.
        let tolerated = style == .polished ? 0.65 : 0.34
        if unknown.count >= 3 && Double(unknown.count) > tolerated * Double(cleanedWords.count) { return "result contains many words that weren't said" }
        return nil
    }

    private static func words(_ s: String) -> [String] {
        s.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'") }.map(String.init)
    }
}
