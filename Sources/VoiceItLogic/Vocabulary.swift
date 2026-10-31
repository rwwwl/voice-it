import Foundation

/// One line of the vocabulary list: either a correction ("heard as" becomes the correct spelling) or a plain term (a word to spell correctly).
public struct VocabularyRow: Identifiable, Equatable, Sendable {
    public let term: String
    /// What the speech model tends to hear instead; nil for a plain term.
    public let heard: String?
    public var isCorrection: Bool { heard != nil }
    public var id: String { (heard ?? "").lowercased() + "\u{1}" + term.lowercased() }
    public init(term: String, heard: String?) { self.term = term; self.heard = heard }
}

public enum VocabularyProblem: Error, Equatable, Sendable {
    case emptyCorrect
    case tooLong
    case sameAsHeard
    case duplicateTerm(existing: String)
    case duplicateHeard(heard: String, term: String)
    case limitReached

    public var message: String {
        switch self {
        case .emptyCorrect: return "Correct spelling can't be empty."
        case .tooLong: return "Keep each entry under \(Vocabulary.maxLength) characters."
        case .sameAsHeard: return "Heard as and Correct spelling are the same. Leave Heard as empty to add a plain term."
        case .duplicateTerm(let existing): return "Already in the list as \u{201C}\(existing)\u{201D}."
        case .duplicateHeard(let heard, let term): return "\u{201C}\(heard)\u{201D} is already corrected to \u{201C}\(term)\u{201D}."
        case .limitReached: return "The list is full (\(Vocabulary.limit) entries). Remove one to add another."
        }
    }
}

/// The vocabulary rules, working on the settings file's dictionary (one term with any number of "heard as" spellings).
/// The window shows one row per heard-as spelling, so the file keeps its shape and nothing in it changes meaning.
public enum Vocabulary {
    /// Measured with `voice-it-harness --vocab-bench`: the cleanup itself hardly slows with a long list, but after every
    /// change the model re-reads its instructions once, which takes about 2.5 s at 100 terms and 3.6 s at 200, against a 3 s timeout.
    /// So the list stops at 150 and warns from 100.
    public static let limit = 150
    public static let warnAt = 100
    public static let maxLength = 80

    public typealias Entries = [Config.DictionaryEntry]

    public static func rows(_ entries: Entries) -> [VocabularyRow] {
        entries.flatMap { entry -> [VocabularyRow] in
            entry.heardAs.isEmpty ? [VocabularyRow(term: entry.term, heard: nil)] : entry.heardAs.map { VocabularyRow(term: entry.term, heard: $0) }
        }.sorted {
            let a = $0.term.localizedCaseInsensitiveCompare($1.term)
            return a == .orderedSame ? ($0.heard ?? "") < ($1.heard ?? "") : a == .orderedAscending
        }
    }

    public static func count(_ entries: Entries) -> Int { entries.reduce(0) { $0 + max(1, $1.heardAs.count) } }

    static func clean(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Adds a correction (heard and correct) or, with `heard` empty, a plain term. Throws the first problem found.
    public static func adding(heard rawHeard: String?, correct rawCorrect: String, to entries: Entries) throws -> Entries {
        let correct = clean(rawCorrect)
        let heard = rawHeard.map(clean).flatMap { $0.isEmpty ? nil : $0 }
        guard !correct.isEmpty else { throw VocabularyProblem.emptyCorrect }
        guard correct.count <= maxLength, (heard?.count ?? 0) <= maxLength else { throw VocabularyProblem.tooLong }
        if let heard {
            guard heard.lowercased() != correct.lowercased() else { throw VocabularyProblem.sameAsHeard }
            if let clash = entries.first(where: { $0.heardAs.contains { $0.lowercased() == heard.lowercased() } }) {
                throw VocabularyProblem.duplicateHeard(heard: heard, term: clash.term)
            }
        }
        var result = entries
        if let i = result.firstIndex(where: { $0.term.lowercased() == correct.lowercased() }) {
            // The term is already there: a different capitalisation, or a plain term added twice, is a duplicate. A new correction joins it.
            guard let heard, result[i].term == correct else { throw VocabularyProblem.duplicateTerm(existing: result[i].term) }
            guard count(entries) < limit else { throw VocabularyProblem.limitReached }
            result[i].heardAs.append(heard)
            return result
        }
        guard count(entries) < limit else { throw VocabularyProblem.limitReached }
        result.append(Config.DictionaryEntry(term: correct, heardAs: heard.map { [$0] } ?? []))
        return result
    }

    /// Removes one row. A term left with no spellings and no row disappears with it.
    public static func removing(_ row: VocabularyRow, from entries: Entries) -> Entries {
        var result = entries
        guard let i = result.firstIndex(where: { $0.term == row.term }) else { return entries }
        if let heard = row.heard, let j = result[i].heardAs.firstIndex(of: heard) {
            result[i].heardAs.remove(at: j)
            if result[i].heardAs.isEmpty { result.remove(at: i) }
        } else if row.heard == nil, result[i].heardAs.isEmpty {
            result.remove(at: i)
        }
        return result
    }

    /// Changes a row. On a problem nothing changes (the throw happens before anything is kept).
    public static func replacing(_ row: VocabularyRow, heard: String?, correct: String, in entries: Entries) throws -> Entries {
        try adding(heard: heard, correct: correct, to: removing(row, from: entries))
    }

    public struct BulkResult: Equatable, Sendable {
        public var entries: Entries
        public var added = 0
        public var skipped: [Skipped] = []
        public struct Skipped: Equatable, Sendable { public let line: Int; public let text: String; public let reason: String }
        public var summary: String {
            "Added \(added), skipped \(skipped.count)."
        }
    }

    /// One entry per line. `heard = correct` (or `->`, `→`, `=>`) is a correction; a line with no arrow is a plain term. Blank lines are ignored.
    public static func addingMany(_ text: String, to entries: Entries) -> BulkResult {
        var result = BulkResult(entries: entries)
        for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            var heard: String?, correct = trimmed
            if let r = trimmed.range(of: #"\s*(->|→|=>|=)\s*"#, options: .regularExpression) {
                heard = String(trimmed[..<r.lowerBound]); correct = String(trimmed[r.upperBound...])
            }
            do { result.entries = try adding(heard: heard, correct: correct, to: result.entries); result.added += 1 }
            catch let problem as VocabularyProblem { result.skipped.append(.init(line: n + 1, text: trimmed, reason: problem.message)) }
            catch { result.skipped.append(.init(line: n + 1, text: trimmed, reason: "\(error)")) }
        }
        return result
    }

    /// The list as text, in the same one-per-line format "Add many" reads.
    public static func listText(_ entries: Entries) -> String {
        rows(entries).map { row in row.heard.map { "\($0) = \(row.term)" } ?? row.term }.joined(separator: "\n")
    }

    /// Search over both columns, case-insensitive.
    public static func matches(_ row: VocabularyRow, search: String) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || row.term.localizedCaseInsensitiveContains(q) || (row.heard?.localizedCaseInsensitiveContains(q) ?? false)
    }
}
