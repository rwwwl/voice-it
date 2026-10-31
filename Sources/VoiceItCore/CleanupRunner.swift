import Foundation

/// Runs the cleanup model over a prepared transcript: whole if it is short, in pieces if it is long.
/// Every piece has its own timeout and safety check, and the whole run has a time budget. A piece that fails, is rejected or
/// runs out of budget keeps its rules-only text, so nothing said is ever lost.
public enum CleanupRunner {
    public struct Outcome {
        /// The final text (placeholders put back), or nil if the model lost a protected phrase and the caller should use the rules-only text.
        public let text: String?
        /// One reason for each piece that was not cleaned.
        public let problems: [String]
        public let pieces: Int
        public var summary: String? {
            guard let first = problems.first else { return nil }
            return pieces == 1 ? first : "\(problems.count) of \(pieces) pieces skipped: \(first)"
        }
    }

    public static func run(_ prepared: TextProcessing.Prepared, cleaner: Cleaner, style: Style, terms: [String],
                           timeout: TimeInterval, budget: TimeInterval = Defaults.cleanupBudget) async -> Outcome {
        let start = ProcessInfo.processInfo.systemUptime
        let pieces = TextChunker.split(prepared.forModel)
        var cleaned: [String] = [], problems: [String] = []
        for piece in pieces {
            if ProcessInfo.processInfo.systemUptime - start >= budget { cleaned.append(piece); problems.append("ran out of time"); continue }
            let t = ProcessInfo.processInfo.systemUptime
            let result = await withTimeout(timeout) { try await cleaner.clean(piece, style: style, terms: terms) }
            if let result {
                if let why = CleanupGuard.rejection(raw: piece, cleaned: result.text, terms: terms, style: style) { cleaned.append(piece); problems.append(why) }
                else { cleaned.append(result.text) }
            } else {
                cleaned.append(piece)
                problems.append(ProcessInfo.processInfo.systemUptime - t >= timeout ? "timed out after \(timeout) s" : "the cleanup model failed")
            }
        }
        guard let restored = prepared.restore(cleaned.joined(separator: " ")) else {
            return Outcome(text: nil, problems: ["the model lost a protected phrase"], pieces: pieces.count)
        }
        return Outcome(text: restored, problems: problems, pieces: pieces.count)
    }
}
