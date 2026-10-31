import Foundation

/// Remembers the last dictation so "Copy last dictation" works. Two storage modes, chosen by the `history.enabled` setting:
///  * memory only (default): kept while the app is open, gone when it quits. Nothing is written to disk.
///  * history on: also appended, as text, to history.jsonl (one line per dictation) so it survives a restart.
/// Only text is ever stored, never audio. The caller decides what is storable (a password field is not).
public final class LastDictationStore {
    public struct Entry: Codable, Equatable, Sendable {
        public var date: Date
        /// What the speech model heard.
        public var raw: String
        /// What was pasted or copied (after the rules and the cleanup model).
        public var text: String
        public init(date: Date = Date(), raw: String, text: String) { self.date = date; self.raw = raw; self.text = text }
    }

    public static let url = Paths.applicationSupport.appendingPathComponent("history.jsonl")
    public let fileURL: URL
    private var latest: Entry?
    private let lock = NSLock()

    public init(fileURL: URL = LastDictationStore.url) { self.fileURL = fileURL }

    /// Keeps the dictation in memory and, with history on, adds it to the history file. Empty text is ignored.
    public func record(raw: String, text: String, history: Bool, date: Date = Date()) {
        guard !text.isEmpty else { return }
        let entry = Entry(date: date, raw: raw, text: text)
        lock.lock(); defer { lock.unlock() }
        latest = entry
        guard history else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])   // only the owner can read it
        }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile(); handle.write(line); try? handle.close()
        } else {
            Log.info("could not write the history file")
        }
    }

    /// The most recent dictation: from memory, or (only with history on) the last line of the history file, for after a restart.
    public func last(history: Bool) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        if let latest { return latest }
        guard history, let data = try? Data(contentsOf: fileURL), let text = String(data: data, encoding: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for line in text.split(separator: "\n").reversed() {
            if let entry = try? decoder.decode(Entry.self, from: Data(line.utf8)) { latest = entry; return entry }
        }
        return nil
    }
}
