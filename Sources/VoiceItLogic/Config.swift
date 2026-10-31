import Foundation

/// Plain JSON settings at ~/Library/Application Support/Voice It/config.json. Written with defaults on first run, then yours to edit.
/// Re-read automatically when the file changes, so edits apply to the next dictation.
public struct Config: Codable, Equatable {
    public struct Cleanup: Codable, Equatable {
        /// Folder name under Application Support/Voice It/models/cleanup/ (used by the Natural and Polished styles).
        public var model = "Qwen3-4B-Instruct-2507-4bit"
        /// Cleanup that takes longer than this is abandoned and the text is pasted without it.
        public var timeoutSeconds = 3.0
        /// Whether the model stays in memory (the default) or is freed after `idleMinutes` without use.
        public var memory = ModelMemory.keepReady
        /// With "freeWhenIdle": minutes without a dictation that used the model before it is freed.
        public var idleMinutes = 10
        /// Natural style: text with more words than this goes to the model even without a correction cue.
        public var naturalLongTextWords = 30
        public static let idleMinutesRange = 1...240
        public static let longTextWordsRange = 10...200
        public init() {}
        private enum CodingKeys: String, CodingKey { case model, timeoutSeconds, memory, idleMinutes, naturalLongTextWords }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Cleanup()
            model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
            timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? d.timeoutSeconds
            memory = try c.decodeIfPresent(ModelMemory.self, forKey: .memory) ?? d.memory
            idleMinutes = try Self.number(c, .idleMinutes, default: d.idleMinutes, range: Self.idleMinutesRange)
            naturalLongTextWords = try Self.number(c, .naturalLongTextWords, default: d.naturalLongTextWords, range: Self.longTextWordsRange)
        }
        private static func number(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys, default value: Int, range: ClosedRange<Int>) throws -> Int {
            guard let n = try c.decodeIfPresent(Int.self, forKey: key) else { return value }
            guard range.contains(n) else {
                throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath + [key], debugDescription: "\(n) is out of range. Use a whole number from \(range.lowerBound) to \(range.upperBound)"))
            }
            return n
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(model, forKey: .model)
            try c.encode(timeoutSeconds, forKey: .timeoutSeconds)
            try c.encode(memory, forKey: .memory)
            try c.encode(idleMinutes, forKey: .idleMinutes)
            try c.encode(naturalLongTextWords, forKey: .naturalLongTextWords)
        }
    }
    public struct Debug: Codable, Equatable {
        /// Writes what was heard and what was pasted into the log. Off by default: those are your words.
        /// Timing numbers are always logged either way.
        public var logTranscripts = false
        /// Developer option: keep a copy of the audio of every dictation in Application Support/Voice It/audio, so real test clips
        /// can be built from actual use. Off by default (it's your voice). Never deleted automatically: delete the files yourself.
        public var keepAudio = false
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            logTranscripts = try c.decodeIfPresent(Bool.self, forKey: .logTranscripts) ?? false
            keepAudio = try c.decodeIfPresent(Bool.self, forKey: .keepAudio) ?? false
        }
    }
    public struct History: Codable, Equatable {
        /// Off (the default): the last dictation is kept in memory only, and is gone when the app quits.
        /// On: the text of each dictation (what was heard and what was pasted) is also saved to history.jsonl, so it survives a restart.
        /// Text only, never audio.
        public var enabled = false
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        }
    }
    public struct DictionaryEntry: Codable, Equatable {
        public var term: String
        /// Known mishearings, replaced (case-insensitive, whole words) with `term` before cleanup.
        public var heardAs: [String] = []
        public init(term: String, heardAs: [String] = []) { self.term = term; self.heardAs = heardAs }
    }
    public struct Snippet: Codable, Equatable {
        public var trigger: String
        public var expansion: String
        public init(trigger: String, expansion: String) { self.trigger = trigger; self.expansion = expansion }
    }

    public init() {}

    /// Keys missing from the file fall back to the defaults, so an older or hand-trimmed config still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        cleanup = try c.decodeIfPresent(Cleanup.self, forKey: .cleanup) ?? d.cleanup
        debug = try c.decodeIfPresent(Debug.self, forKey: .debug) ?? d.debug
        history = try c.decodeIfPresent(History.self, forKey: .history) ?? d.history
        // An unknown key name is a settings error (named in the menu), not a silent fallback: the last good settings stay in use.
        if let raw = try c.decodeIfPresent(String.self, forKey: .hotkey) {
            guard let key = Hotkey(rawValue: raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath + [CodingKeys.hotkey],
                    debugDescription: "unknown hotkey \"\(raw)\". Choices: \(Hotkey.allCases.map(\.rawValue).joined(separator: ", "))"))
            }
            hotkey = key
        } else { hotkey = d.hotkey }
        if let raw = try c.decodeIfPresent(String.self, forKey: .copyModifier) {
            guard let key = Hotkey(rawValue: raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath + [CodingKeys.copyModifier],
                    debugDescription: "unknown key \"\(raw)\". Choices: \(Hotkey.allCases.map(\.rawValue).joined(separator: ", "))"))
            }
            copyModifier = key
        } else { copyModifier = d.copyModifier }
        if copyModifier == hotkey || copyModifier.isShift {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath + [CodingKeys.copyModifier],
                debugDescription: copyModifier == hotkey
                    ? "the copy key can't be the same as the hotkey (\(hotkey.rawValue)). Choose another, for example rightControl"
                    : "Shift is used for hands-free, so it can't be the copy key. Choose another, for example rightCommand"))
        }
        style = try c.decodeIfPresent(StyleChoice.self, forKey: .style) ?? d.style
        appStyles = try c.decodeIfPresent([String: Style].self, forKey: .appStyles) ?? d.appStyles
        dictionary = try c.decodeIfPresent([DictionaryEntry].self, forKey: .dictionary) ?? d.dictionary
        snippets = try c.decodeIfPresent([Snippet].self, forKey: .snippets) ?? d.snippets
    }

    /// Hold-to-talk key: rightOption (default), leftOption, rightCommand, leftCommand, rightControl, leftControl, rightShift or leftShift.
    public var hotkey = Hotkey.rightOption
    /// Hold this together with the hotkey and the text is copied to the clipboard instead of pasted. Must differ from the hotkey and not be Shift.
    public var copyModifier = Hotkey.rightCommand
    public var cleanup = Cleanup()
    public var debug = Debug()
    public var history = History()
    /// Exact, Natural (default), Polished, or Automatic by app.
    public var style = StyleChoice.natural
    /// App bundle identifier -> style. Used only when `style` is automatic; apps not listed use Natural.
    public var appStyles: [String: Style] = [
        "com.tinyspeck.slackmacgap": .natural,   // Slack
        "com.apple.MobileSMS": .natural,         // Messages
        "ru.keepcoder.Telegram": .natural,
        "net.whatsapp.WhatsApp": .natural,
        "com.apple.mail": .polished,             // Mail
        "com.apple.Terminal": .exact,
        "com.apple.dt.Xcode": .exact,
    ]
    /// Empty by default: a shared build must not ship the developer's own words. The Vocabulary window adds to it.
    public var dictionary: [DictionaryEntry] = []
    /// The vocabulary the project's own cleanup samples and tests assume (it is not a default for anyone).
    public static let exampleDictionary: [DictionaryEntry] = [
        .init(term: "Parakeet", heardAs: ["para keet", "parrot keet"]),
        .init(term: "FluidAudio", heardAs: ["fluid audio"]),
        .init(term: "Neural Engine", heardAs: ["neural engine"]),
        .init(term: "Xcode"),
        .init(term: "SwiftUI", heardAs: ["swift ui"]),
    ]
    /// A spoken trigger phrase that expands to longer text, for example {"trigger": "my address", "expansion": "..."}.
    public var snippets: [Snippet] = []

    /// The style this dictation uses: the chosen style, or for Automatic the one listed for the app in front (Natural if it isn't listed).
    public func effectiveStyle(forApp bundleID: String?) -> Style {
        if let fixed = style.fixed { return fixed }
        return bundleID.flatMap { appStyles[$0] } ?? .natural
    }

    /// The styles that may send text to the cleanup model under the current settings, so their instructions can be prepared ahead of time.
    /// A fixed style gives just itself (none for Exact); Automatic gives every non-Exact style in the app list, plus Natural for apps not listed.
    public var stylesThatMayUseModel: [Style] {
        if let fixed = style.fixed { return fixed.canUseModel ? [fixed] : [] }
        return Set(appStyles.values.filter(\.canUseModel)).union([.natural]).sorted { $0.rawValue < $1.rawValue }
    }

    public var cleanupModelDirectory: URL {
        Paths.applicationSupport.appendingPathComponent("models/cleanup/\(cleanup.model)", isDirectory: true)
    }
}

/// What is wrong with the settings file and where, in words the owner can act on.
public struct ConfigProblem: Equatable, Sendable {
    public var message: String
    public var line: Int?
    public var column: Int?
    public init(message: String, line: Int? = nil, column: Int? = nil) { self.message = message; self.line = line; self.column = column }

    /// "line 12, column 5" (or just "line 12"), or nil when the position is unknown.
    public var location: String? {
        guard let line else { return nil }
        return column.map { "line \(line), column \($0)" } ?? "line \(line)"
    }
    public var summary: String { location.map { "\($0): \(message)" } ?? message }

    /// Works out the problem from a failed load: a JSON syntax error gets an exact position; a wrong value gets the line of its key.
    public static func diagnose(_ error: Error, in data: Data) -> ConfigProblem {
        // Syntax first: Foundation's parser reports the byte where it gave up.
        do { _ = try JSONSerialization.jsonObject(with: data, options: []) }
        catch let e as NSError {
            let offset = (e.userInfo["NSJSONSerializationErrorIndex"] as? Int)
            let detail = (e.userInfo["NSDebugDescription"] as? String) ?? "not valid JSON"
            let pos = offset.map { position(ofByte: $0, in: data) }
            return ConfigProblem(message: "not valid JSON (\(detail.trimmingCharacters(in: CharacterSet(charactersIn: "."))))", line: pos?.line, column: pos?.column)
        }
        guard let decoding = error as? DecodingError else { return ConfigProblem(message: "\(error)") }
        let context: DecodingError.Context
        var message: String
        switch decoding {
        case .typeMismatch(let type, let c): context = c; message = "\(describe(type: type)) expected for \(pathText(c.codingPath))"
        case .valueNotFound(_, let c): context = c; message = "missing value for \(pathText(c.codingPath))"
        case .keyNotFound(let key, let c): context = c; message = "missing setting \"\(key.stringValue)\""
        case .dataCorrupted(let c): context = c; message = c.debugDescription
        @unknown default: return ConfigProblem(message: "\(error)")
        }
        if case .dataCorrupted = decoding, !context.codingPath.isEmpty { message = "\(pathText(context.codingPath)): \(message)" }
        let pos = locate(path: context.codingPath.map(\.stringValue), in: data)
        return ConfigProblem(message: message, line: pos?.line, column: pos?.column)
    }

    private static func describe(type: Any.Type) -> String {
        switch type {
        case is String.Type: return "text in quotes"
        case is Bool.Type: return "true or false"
        case is Double.Type, is Int.Type: return "a number"
        case is Array<Any>.Type: return "a list"
        default: return "a different kind of value"
        }
    }

    private static func pathText(_ path: [CodingKey]) -> String {
        path.isEmpty ? "the settings" : "\"" + path.map(\.stringValue).joined(separator: ".") + "\""
    }

    /// 1-based line and column (in bytes) of a byte offset.
    static func position(ofByte offset: Int, in data: Data) -> (line: Int, column: Int) {
        var line = 1, lineStart = 0
        for (i, b) in data.prefix(max(0, offset)).enumerated() where b == 0x0A { line += 1; lineStart = i + 1 }
        return (line, max(0, offset) - lineStart + 1)
    }

    /// Finds `"a"` then `"b"` after it, for the path a.b, and reports where the last one starts. Approximate, but close enough to point at.
    static func locate(path: [String], in data: Data) -> (line: Int, column: Int)? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var from = text.startIndex
        var found: String.Index?
        for key in path where Int(key) == nil {
            guard let r = text.range(of: "\"\(key)\"", range: from..<text.endIndex) else { break }
            found = r.lowerBound; from = r.upperBound
        }
        guard let found else { return nil }
        return position(ofByte: text.utf8.distance(from: text.startIndex, to: found), in: data)
    }
}

/// Loads the config and reloads it when the file changes.
///
/// The file is the owner's. A mistake in it never costs them their settings: the last good settings stay in use (and are also kept
/// on disk as config.lastgood.json, so a restart with a broken file still works), the problem is reported through `problem`,
/// edits from inside the app are refused until the file is fixed, and the file is never overwritten with defaults. Defaults are
/// written only when there is no file at all, and a missing file is restored from the last good copy when there is one.
public final class ConfigStore {
    public static let url = Paths.applicationSupport.appendingPathComponent("config.json")
    /// The file this store reads and writes: the real settings file, unless a test gives another.
    public let fileURL: URL
    private var cached = Config()
    private var modified: Date?
    private var hasLoaded = false
    private var currentProblem: ConfigProblem?
    private let lock = NSLock()

    public init(fileURL: URL = ConfigStore.url) { self.fileURL = fileURL }

    /// Called on the main queue shortly after anything in the settings folder is added, replaced or removed (an editor saving, or this app).
    /// The callback should re-read what it needs; it may fire more than once for one save, and for changes that don't matter.
    public var onChange: (() -> Void)?
    private var watcher: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    /// Starts watching the settings folder, so edits are noticed straight away without polling. Atomic saves (write a temporary file,
    /// then rename it over the real one) change the folder, which is why the folder is watched and not the file.
    public func startWatching() {
        guard watcher == nil else { return }
        let fd = open(fileURL.deletingLastPathComponent().path, O_EVTONLY)
        guard fd >= 0 else { Log.info("settings folder can't be watched; relying on the periodic check"); return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.pending?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.onChange?() }      // let a save finish, and merge a burst into one call
            self.pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    private var lastGoodURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("config.lastgood.json") }

    /// The current problem with the settings file, or nil when it loaded fine. Call `current()` first to refresh it.
    public var problem: ConfigProblem? { lock.lock(); defer { lock.unlock() }; return currentProblem }

    public func current() -> Config {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            restoreOrWriteDefaults()
            return cached
        }
        guard let date = modificationDate() else { return cached }      // unreadable right now (an editor mid-save): try again next time
        if date != modified || !hasLoaded {
            modified = date
            load()
        }
        return cached
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            cached = try JSONDecoder().decode(Config.self, from: data)
            hasLoaded = true
            if currentProblem != nil { Log.info("config.json is fine again") }
            currentProblem = nil
            Log.info("config loaded from \(fileURL.path)")
            saveLastGood(data)
        } catch {
            let found = ConfigProblem.diagnose(error, in: data)
            currentProblem = found
            Log.info("config.json has an error, so the last good settings stay in use. \(found.summary)")
            if !hasLoaded, let good = try? Data(contentsOf: lastGoodURL), let config = try? JSONDecoder().decode(Config.self, from: good) {
                cached = config      // first read after a restart: fall back to the last good copy on disk, not to defaults
                Log.info("using the last good settings saved on disk")
            }
            hasLoaded = true
        }
    }

    private func saveLastGood(_ data: Data) {
        if (try? Data(contentsOf: lastGoodURL)) == data { return }
        try? data.write(to: lastGoodURL, options: .atomic)
    }

    /// Changes the config from inside the app (for example the Cleanup menu) and saves it. The previous file is kept once per
    /// launch as config.json.bak, because writing the file back drops anything the app doesn't know about.
    /// Refused while the file has an error (so a broken file is never overwritten), or if the file changed since it was read.
    @discardableResult
    public func update(_ change: (inout Config) -> Void) -> Bool {
        var config = current()
        let before = config
        change(&config)
        guard config != before else { return false }
        lock.lock(); defer { lock.unlock() }
        if let currentProblem { Log.info("settings not saved, the file has an error: \(currentProblem.summary)"); return false }
        let fm = FileManager.default
        guard modificationDate() == modified else { Log.info("settings not saved, the file changed while it was being edited; try again"); return false }
        if !madeBackup, fm.fileExists(atPath: fileURL.path) {
            let backup = fileURL.deletingLastPathComponent().appendingPathComponent("config.json.bak")
            try? fm.removeItem(at: backup)
            try? fm.copyItem(at: fileURL, to: backup)
            madeBackup = true
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config), (try? data.write(to: fileURL, options: .atomic)) != nil else {
            Log.info("could not save config.json")
            return false
        }
        cached = config
        modified = modificationDate()
        saveLastGood(data)
        return true
    }

    private var madeBackup = false

    /// Only reached when there is no settings file. Restores the last good copy if one exists, otherwise writes the defaults.
    private func restoreOrWriteDefaults() {
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let good = try? Data(contentsOf: lastGoodURL), let config = try? JSONDecoder().decode(Config.self, from: good),
           (try? good.write(to: fileURL, options: .atomic)) != nil {
            cached = config; hasLoaded = true; currentProblem = nil; modified = modificationDate()
            Log.info("config.json was missing; restored the last good settings")
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(Config()), (try? data.write(to: fileURL, options: .atomic)) != nil {
            cached = Config(); hasLoaded = true; currentProblem = nil; modified = modificationDate()
            saveLastGood(data)
            Log.info("wrote default config to \(fileURL.path)")
        }
    }
}
