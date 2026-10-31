import Foundation

/// Natural style: should this text go to the cleanup model? Looks only at the words (the text after the rules have run), never at how
/// sure the speech model was. When in doubt it says yes: a needless call costs about 270 ms, a needless skip costs a missed tidy-up.
public enum NaturalPolicy {
    public enum Reason: Equatable, Sendable {
        case correctionCue, repeatedWords, fillerPhrase, long

        /// A short label for the log. It names the kind of trigger, never the words themselves.
        public var label: String {
            switch self {
            case .correctionCue: return "correction cue"
            case .repeatedWords: return "repeated words"
            case .fillerPhrase: return "filler phrase"
            case .long: return "long text"
            }
        }
    }

    /// Words and phrases that usually mean the speaker is correcting themselves.
    static let cues: [[String]] = [
        ["actually"], ["i", "mean"], ["i", "meant"], ["sorry"], ["wait"], ["scratch", "that"], ["make", "that"],
        ["never", "mind"], ["nevermind"], ["or", "rather"], ["let", "me", "rephrase"],
    ]
    /// Filler phrases the rules deliberately leave alone (they remove only um, uh, er, erm and ah).
    static let fillers: [[String]] = [["you", "know"], ["kind", "of"], ["sort", "of"], ["or", "something"], ["or", "whatever"], ["basically"]]
    /// What may follow a "no" that is not a correction ("no problem", "no idea"). Any other "no" counts as a cue, because the speech model does
    /// not always write the commas around a self-correction ("tuesday no wednesday"), and calling the model needlessly is cheap.
    static let noIdioms: Set<String> = [
        "problem", "problems", "worries", "idea", "one", "longer", "more", "matter", "way", "need", "doubt", "thanks", "thank", "other", "such",
        "sign", "chance", "point", "reason", "time", "rush", "hurry", "issue", "issues", "change", "changes", "difference", "update", "updates",
        "news", "progress", "answer", "luck", "fault", "harm", "trouble", "objection", "objections", "less", "fewer", "sooner", "good", "bad",
    ]
    /// Words that are properly said twice in a row.
    static let allowedDoubles: Set<String> = ["had", "that"]

    /// The first trigger found, or nil for short, clean text.
    public static func reason(for text: String, longTextWords: Int) -> Reason? {
        let words = tokens(text)
        if containsCue(text, words) { return .correctionCue }
        if hasRepeat(words) { return .repeatedWords }
        if contains(words, any: fillers) { return .fillerPhrase }
        if words.count > longTextWords { return .long }
        return nil
    }

    public static func tokens(_ s: String) -> [String] {
        s.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "’") }.map { String($0).replacingOccurrences(of: "’", with: "'") }
    }

    private static func containsCue(_ text: String, _ words: [String]) -> Bool {
        if contains(words, any: cues) { return true }
        // "no," is always a cue; a "no" with nothing between it and the next word is one unless the next word makes it an idiom.
        if text.range(of: #"\bno\s*,"#, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        return words.indices.contains { words[$0] == "no" && !($0 + 1 < words.count && noIdioms.contains(words[$0 + 1])) }
    }

    private static func contains(_ words: [String], any phrases: [[String]]) -> Bool {
        phrases.contains { p in
            guard words.count >= p.count else { return false }
            return (0...(words.count - p.count)).contains { Array(words[$0..<($0 + p.count)]) == p }
        }
    }

    /// The same word twice in a row, or the same two or three words twice in a row ("can you can you").
    private static func hasRepeat(_ w: [String]) -> Bool {
        for n in 1...3 {
            guard w.count >= 2 * n else { continue }
            for i in 0...(w.count - 2 * n) where Array(w[i..<(i + n)]) == Array(w[(i + n)..<(i + 2 * n)]) {
                if n == 1 && (allowedDoubles.contains(w[i]) || Int(w[i]) != nil) { continue }
                return true
            }
        }
        return false
    }
}
