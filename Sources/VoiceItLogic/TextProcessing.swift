import Foundation

/// Work done in code, around the model: filler words, dictionary fixes, snippets and spoken formatting.
/// Snippet expansions and line breaks become placeholders before cleanup and are put back afterwards,
/// so the model can't reword them. If the model loses a placeholder, its output is thrown away.
public enum TextProcessing {
    public struct Prepared {
        /// Text to send to the model (placeholders in place).
        public let forModel: String
        let replacements: [String: String]
        let terms: [String]
        /// Fallback text when cleanup is skipped: same substitutions, no model.
        public var raw: String { TextProcessing.finish(Self.fill(forModel, replacements), terms: terms) }

        /// Puts expansions back. Returns nil if the model dropped or duplicated a placeholder.
        public func restore(_ cleaned: String) -> String? {
            for token in replacements.keys where cleaned.components(separatedBy: token).count != 2 { return nil }
            return TextProcessing.finish(Self.fill(cleaned, replacements), terms: terms)
        }

        static func fill(_ text: String, _ replacements: [String: String]) -> String {
            var out = text
            for (token, value) in replacements { out = out.replacingOccurrences(of: token, with: value) }
            return out
        }
    }

    /// The text to paste when no language model is involved ("rules only", and "with cleanup" when the model is skipped or fails):
    /// fillers, dictionary, snippets and spoken formatting.
    public static func withoutModel(_ heard: String, config: Config) -> String {
        prepare(heard, config: config).raw
    }

    /// Removes "um", "uh", "er", "erm" and "ah" (any number of repeated letters, any case) with the comma that went with them.
    /// Deliberately not "you know" or "like", which can be real words. Hyphenated words ("uh-huh") are left alone.
    public static func removeFillers(_ text: String) -> String {
        let pattern = #"(\s*,)?(\s*)(?<![-'’\p{L}])(?:um+|uh+|erm+|er+|ah+)(?![-'’\p{L}])(\s*,)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let ns = text as NSString
        var out = "", last = 0
        var capitaliseNext = false
        func append(_ piece: String) {
            guard !piece.isEmpty else { return }
            if capitaliseNext, let i = piece.firstIndex(where: { $0.isLetter }), piece[piece.startIndex..<i].allSatisfy({ $0 == " " }) {
                out += piece[piece.startIndex..<i] + piece[i].uppercased() + piece[piece.index(after: i)...]
                capitaliseNext = false
            } else { out += piece; if piece.contains(where: { !$0.isWhitespace }) { capitaliseNext = false } }
        }
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            let before = m.range(at: 1).location != NSNotFound, after = m.range(at: 3).location != NSNotFound
            if before && after { out += "," }
            let word = ns.substring(with: m.range).trimmingCharacters(in: CharacterSet(charactersIn: " \t,"))
            if word.first?.isUppercase == true, word.dropFirst().contains(where: { $0.isLowercase }) || word.count == 1 { capitaliseNext = true }   // "Um," started a sentence, so the next word now does; "UHHH" is just loud
            last = m.range.location + m.range.length
        }
        append(ns.substring(from: last))
        return out.trimmingCharacters(in: .whitespaces)
    }

    public static func prepare(_ text: String, config: Config) -> Prepared {
        var out = text
        var replacements: [String: String] = [:]
        var counter = 0
        func placeholder(for value: String) -> String {
            counter += 1
            let token = "ZZ\(counter)ZZ"
            replacements[token] = value
            return token
        }

        // 0. Filler words.
        out = removeFillers(out)
        // 1. Known mishearings -> correct spelling.
        for entry in config.dictionary {
            for heard in entry.heardAs { out = replaceWholeWord(heard, with: entry.term, in: out) }
        }
        // 2. Snippets: the expansion is protected from the model.
        for snippet in config.snippets where !snippet.trigger.isEmpty {
            out = replaceWholeWord(snippet.trigger, with: nil, in: out) { placeholder(for: snippet.expansion) }
        }
        // 3. Spoken formatting. Line breaks are protected; punctuation words just become punctuation.
        out = replaceWholeWord("new paragraph", with: nil, in: out, swallowPunctuation: true) { " " + placeholder(for: "\n\n") + " " }
        out = replaceWholeWord("new line", with: nil, in: out, swallowPunctuation: true) { " " + placeholder(for: "\n") + " " }
        out = replaceWholeWord("question mark", with: "?", in: out, attachToPrevious: true)
        out = replaceWholeWord("exclamation mark", with: "!", in: out, attachToPrevious: true)
        out = replaceWholeWord("exclamation point", with: "!", in: out, attachToPrevious: true)
        return Prepared(forModel: out, replacements: replacements, terms: config.dictionary.map(\.term))
    }

    /// Final tidy: dictionary spelling, then clean up around any line breaks that spoken formatting inserted.
    static func finish(_ text: String, terms: [String]) -> String {
        var out = fixSpelling(text, terms: terms)
        guard out.contains("\n") else { return out }
        func sub(_ pattern: String, _ template: String) {
            out = out.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        sub("[ \\t]+(?=\\n)", "")            // spaces before a break
        sub("(\\n+)[ \\t,;.]+", "$1")        // spaces or stray punctuation after a break
        sub("^[ \\t]+", "")
        // Start each new line with a capital letter.
        let ns = out as NSString
        var chars = Array(out)
        var i = 0
        while i < chars.count {
            if chars[i] == "\n", i + 1 < chars.count, chars[i + 1].isLowercase { chars[i + 1] = Character(chars[i + 1].uppercased()) }
            i += 1
        }
        _ = ns
        return String(chars)
    }

    /// The model sometimes lowercases dictionary terms; put the dictionary's spelling back (whole words, any case).
    static func fixSpelling(_ text: String, terms: [String]) -> String {
        var out = text
        for term in terms { out = replaceWholeWord(term, with: term, in: out) }
        return out
    }

    private static func replaceWholeWord(_ phrase: String, with fixed: String?, in text: String, swallowPunctuation: Bool = false,
                                         attachToPrevious: Bool = false, make: (() -> String)? = nil) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: phrase).replacingOccurrences(of: "\\ ", with: "\\s+")
        // Optional comma/full stop on either side of the phrase belongs to the phrase when it is a command.
        var pattern = "\\b\(escaped)\\b"
        if attachToPrevious { pattern = "\\s*[,.]?\\s*" + pattern + "[.,]?" }
        else if swallowPunctuation { pattern = "[ \\t]*[,.]?[ \\t]*" + pattern + "[,.]?[ \\t]*" }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        var result = ""
        var last = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[last..<range.lowerBound]
            result += make?() ?? fixed ?? ""
            last = range.upperBound
        }
        result += text[last...]
        return result
    }
}
