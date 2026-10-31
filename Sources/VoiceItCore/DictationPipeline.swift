import AppKit
import Foundation

/// Key release → transcribe → clean up → paste. Dictations are handled one at a time, in order.
public final class DictationPipeline {
    public enum Outcome: Equatable {
        case pasted
        case pastedWithoutCleanup(String)   // reason: timed out, model failed, result rejected, or no model
        case noSpeech
        case copied                         // the copy modifier was held: copied to the clipboard on purpose, nothing pasted
        case copiedAppChanged               // a different app was in front at key press than is now
        case copiedNoAccessibility          // Accessibility not granted, so Cmd-V can't be sent
        case blockedPasswordField           // a password field (secure input) is active: nothing is pasted, copied, kept or logged
        case failed(String)
    }

    public struct Report {
        public let text: String
        public let rawText: String
        public let outcome: Outcome
        public let style: Style
        public let audioDuration: TimeInterval
        /// Recording time after the key was released.
        public let tail: TimeInterval
        public let waitedForModel: TimeInterval
        public let transcribe: TimeInterval
        public let cleanup: TimeInterval
        /// Key release to Cmd-V posted (nil when nothing was pasted).
        public let releaseToPaste: TimeInterval?
        public let residentMB: Double
        /// Whether the cleanup model was used for this dictation and why, never the words ("model skipped (short clean text)").
        public let modelUse: String

        public init(text: String, rawText: String, outcome: Outcome, style: Style, audioDuration: TimeInterval, tail: TimeInterval,
                    waitedForModel: TimeInterval, transcribe: TimeInterval, cleanup: TimeInterval, releaseToPaste: TimeInterval?, residentMB: Double,
                    modelUse: String = "") {
            self.modelUse = modelUse
            self.text = text; self.rawText = rawText; self.outcome = outcome; self.style = style; self.audioDuration = audioDuration; self.tail = tail
            self.waitedForModel = waitedForModel; self.transcribe = transcribe; self.cleanup = cleanup; self.releaseToPaste = releaseToPaste; self.residentMB = residentMB
        }
    }

    public enum Status {
        case modelLoading, modelReady(speechSeconds: Double, cleanupSeconds: Double?), modelFailed(String)
        case transcribing, waitingForModel, finished(Report)
    }

    /// Called on the main thread.
    public var onStatus: ((Status) -> Void)?

    private let transcriber: Transcriber
    private let output: TextOutput
    private let secureInput: () -> Bool
    private let cleaner: Cleaner?
    private let configStore: ConfigStore
    private var loadTask: Task<Void, Error>?
    private var chain: Task<Void, Never>?
    // The cleanup model's state is touched from the main thread (mode changes) and from dictations, so it sits behind a lock.
    private let readyLock = NSLock()
    private var modelsReady = false
    private var cleanerLoadTask: Task<Bool, Never>?    // non-nil while the cleanup model is loading or loaded
    private var cleanerReady = false
    private var warmed: [Style: [String]] = [:]       // the vocabulary each style's prompt was last prepared with
    private var lastSpeechUse: TimeInterval?          // uptime of the last transcription or warm-up, to decide whether the speech model needs waking
    private var lastModelUse: TimeInterval?           // uptime of the last time the cleanup model loaded or was used, for freeing it when idle
    private var cleanerGeneration = 0                  // bumped on each load or unload, so a stale load can't mark itself ready
    private var isReady: Bool { readyLock.lock(); defer { readyLock.unlock() }; return modelsReady }
    private var cleanerLoading: Task<Bool, Never>? { readyLock.lock(); defer { readyLock.unlock() }; return cleanerLoadTask }
    private var modelState: ModelPlan.ModelState {
        let installed = cleaner?.isInstalled ?? false
        readyLock.lock(); defer { readyLock.unlock() }
        return ModelPlan.ModelState(installed: installed, loaded: cleanerReady, loading: cleanerLoadTask != nil && !cleanerReady)
    }
    private var cleanerIsReady: Bool { readyLock.lock(); defer { readyLock.unlock() }; return cleanerReady }

    /// `output` and `secureInput` are for tests: by default the text goes to the system clipboard and Cmd-V, and a password field is
    /// whatever macOS reports as secure keyboard input.
    public init(transcriber: Transcriber, cleaner: Cleaner?, configStore: ConfigStore,
                output: TextOutput = SystemTextOutput(), secureInput: @escaping () -> Bool = { Paster.secureInputActive }) {
        self.output = output
        self.secureInput = secureInput
        self.transcriber = transcriber
        self.cleaner = cleaner
        self.configStore = configStore
    }

    public func startLoading() {
        status(.modelLoading)
        let start = ProcessInfo.processInfo.systemUptime
        let config = configStore.current()
        // The cleanup model loads alongside the speech model when the settings call for it (Keep ready, and a style that can use it).
        // A failure there only turns cleanup off.
        if ModelPlan.settingsAction(choice: config.style, memory: config.cleanup.memory, model: modelState) == .load { startCleanerLoad(config: config, since: start) }
        loadTask = Task {
            do {
                try await transcriber.load()
                let speech = ProcessInfo.processInfo.systemUptime - start
                let cleanerOK = await cleanerLoading?.value ?? false      // nil when no model is loading: the style or settings don't call for it
                let both = ProcessInfo.processInfo.systemUptime - start
                let mem = Memory.megabytes()
                Log.info(String(format: "models ready: speech %.2f s, everything %.2f s (footprint %.0f MB, resident %.0f MB)", speech, both, mem.footprint, mem.resident))
                readyLock.lock(); modelsReady = true; readyLock.unlock()
                status(.modelReady(speechSeconds: speech, cleanupSeconds: cleanerOK ? both : nil))
            } catch {
                Log.info("model load failed: \(error)")
                status(.modelFailed("\(error)"))
                throw error
            }
        }
    }

    /// Developer option (config debug.keepAudio): saves the recording to Application Support/Voice It/audio. This is the only place audio
    /// is ever written to disk. Plays no part in the dictation itself, and failures only log. The files stay until you delete them.
    private static func keepAudio(_ samples: [Float]) {
        let folder = Paths.applicationSupport.appendingPathComponent("audio", isDirectory: true)
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let name = formatter.string(from: Date()) + ".wav"
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try AudioRecorder.writeWAV(samples, to: folder.appendingPathComponent(name))
            Log.info("kept audio: \(name)")
        } catch { Log.info("could not keep audio: \(error)") }
    }

    /// One log line per dictation. Timings are always included; the words only when `includeText` (config.debug.logTranscripts).
    public static func logLine(_ r: Report, includeText: Bool) -> String {
        var line = String(format: "dictation: %@ | style %@, %@, audio %.2f s, tail %.0f ms, waited %.0f ms, transcribe %.0f ms, cleanup %.0f ms, release→Cmd-V %@, resident %.0f MB",
                          "\(r.outcome)", r.style.rawValue, r.modelUse.isEmpty ? "no model decision" : r.modelUse, r.audioDuration, r.tail * 1000, r.waitedForModel * 1000, r.transcribe * 1000, r.cleanup * 1000,
                          r.releaseToPaste.map { String(format: "%.0f ms", $0 * 1000) } ?? "n/a", r.residentMB)
        if includeText { line += " | raw: \"\(r.rawText)\" | final: \"\(r.text)\"" }
        return line
    }

    /// For the menu.
    public var cleanupModelInstalled: Bool { cleaner?.isInstalled ?? false }
    public var cleanupModelReady: Bool { cleanerIsReady }
    public var cleanupModelLoading: Bool { cleanerLoading != nil && !cleanerIsReady }

    /// Brings the cleanup model in line with the settings: loads it (Keep ready), frees it (Exact style), and frees it after the idle time
    /// (Free memory when idle). Call on the main thread whenever the settings change, and now and then. Does nothing if it already matches.
    public func syncCleanupModel() {
        let config = configStore.current()
        let state = modelState
        let now = ProcessInfo.processInfo.systemUptime
        switch ModelPlan.settingsAction(choice: config.style, memory: config.cleanup.memory, model: state) {
        case .load: startCleanerLoad(config: config, since: now)
        case .unload: unloadCleaner()
        case .none: break
        }
        readyLock.lock(); let last = lastModelUse; readyLock.unlock()
        if ModelPlan.shouldFreeForIdle(memory: config.cleanup.memory, idleMinutes: config.cleanup.idleMinutes, lastUsed: last, now: now, loaded: state.loaded) {
            Log.info("cleanup model unused for \(config.cleanup.idleMinutes) min; freeing its memory")
            unloadCleaner()
        }
    }

    /// At key-down: with Free memory when idle and the Polished style, start loading the model now so it is ready when the key is released.
    /// Call on the main thread. `targetApp` is the app in front.
    public func prepareForDictation(targetApp: String?) {
        warmUpSpeechModelIfNeeded()
        let config = configStore.current()
        let style = config.effectiveStyle(forApp: targetApp)
        guard ModelPlan.loadAtKeyDown(style: style, memory: config.cleanup.memory, model: modelState) else { return }
        Log.info("loading the cleanup model now (\(style.rawValue) style)")
        startCleanerLoad(config: config, since: ProcessInfo.processInfo.systemUptime)
    }

    /// The speech model is slow on its first use after a pause. Waking it now, while the user speaks, hides that. See `SpeechWarmUp`.
    private func warmUpSpeechModelIfNeeded() {
        guard isReady else { return }
        let now = ProcessInfo.processInfo.systemUptime
        readyLock.lock()
        let warm = SpeechWarmUp.shouldWarm(lastUse: lastSpeechUse, now: now)
        if warm { lastSpeechUse = now }
        readyLock.unlock()
        guard warm else { return }
        Task { [transcriber] in
            let t0 = ProcessInfo.processInfo.systemUptime
            await transcriber.warmUp()
            Log.info(String(format: "speech model warm-up %.0f ms", (ProcessInfo.processInfo.systemUptime - t0) * 1000))
        }
    }

    private func startCleanerLoad(config: Config, since start: TimeInterval) {
        guard let cleaner, cleaner.isInstalled else { return }
        readyLock.lock()
        guard cleanerLoadTask == nil else { readyLock.unlock(); return }      // already loading or loaded
        cleanerGeneration += 1
        let generation = cleanerGeneration
        cleanerLoadTask = Task { [weak self] in
            do {
                try await cleaner.load()
                let terms = config.dictionary.map(\.term)
                if let mlx = cleaner as? MLXCleaner {
                    for style in config.stylesThatMayUseModel { await mlx.warmUp(style: style, terms: terms) }
                }
                guard let self else { return false }
                self.readyLock.lock()
                let stillWanted = self.cleanerGeneration == generation
                if stillWanted {
                    self.cleanerReady = true
                    self.lastModelUse = ProcessInfo.processInfo.systemUptime
                    for style in config.stylesThatMayUseModel { self.warmed[style] = terms }
                }
                self.readyLock.unlock()
                if !stillWanted { await cleaner.unload(); return false }      // the settings changed while it was loading
                Log.info(String(format: "cleanup model ready in %.2f s", ProcessInfo.processInfo.systemUptime - start))
                return true
            } catch {
                Log.info("cleanup model unavailable, dictations will be pasted without it: \(error)")
                return false
            }
        }
        readyLock.unlock()
    }

    /// After the vocabulary changes, or a style that needs the model is chosen, the model has to read that style's instructions once
    /// (about 1.6 s). Doing it here, in the background, means the next dictation doesn't pay for it.
    /// Call on the main thread; does nothing unless a style's instructions are out of date.
    public func refreshCleanupPrompt() {
        let config = configStore.current()
        guard let mlx = cleaner as? MLXCleaner else { return }
        let terms = config.dictionary.map(\.term)
        readyLock.lock()
        let stale = cleanerReady ? config.stylesThatMayUseModel.filter { warmed[$0] != terms } : []
        for style in stale { warmed[style] = terms }
        readyLock.unlock()
        guard !stale.isEmpty else { return }
        Task {
            let t0 = ProcessInfo.processInfo.systemUptime
            for style in stale { await mlx.warmUp(style: style, terms: terms) }
            Log.info(String(format: "cleanup instructions refreshed for %@ (%d terms, %.1f s)", stale.map(\.rawValue).joined(separator: ", "), terms.count, ProcessInfo.processInfo.systemUptime - t0))
        }
    }

    private func unloadCleaner() {
        readyLock.lock()
        let wasLoaded = cleanerLoadTask != nil
        cleanerLoadTask = nil; cleanerReady = false; warmed = [:]; lastModelUse = nil; cleanerGeneration += 1
        readyLock.unlock()
        guard wasLoaded, let cleaner else { return }
        Task {
            await cleaner.unload()
            let mem = Memory.megabytes()
            Log.info(String(format: "cleanup model released (resident %.0f MB, footprint %.0f MB)", mem.resident, mem.footprint))
        }
    }

    /// A dictation needs the model and it is not loaded yet: start loading if nothing has, and wait up to `ModelPlan.loadWait` for it.
    private func waitForCleaner(config: Config) async -> Bool {
        startCleanerLoad(config: config, since: ProcessInfo.processInfo.systemUptime)
        guard let task = cleanerLoading else { return false }
        return await withTimeout(ModelPlan.loadWait) { await task.value } ?? false
    }

    /// Call on the main thread at key release. `targetApp` is the app that was in front at key press.
    /// `copyOnly`: put the text on the clipboard and don't paste it (the copy modifier was held).
    public func enqueue(_ recording: AudioRecorder.Result, releasedAt: TimeInterval, targetApp: String?, copyOnly: Bool = false) {
        let previous = chain
        chain = Task { [self] in
            await previous?.value
            await run(recording, releasedAt: releasedAt, targetApp: targetApp, copyOnly: copyOnly)
        }
    }

    private func run(_ recording: AudioRecorder.Result, releasedAt: TimeInterval, targetApp: String?, copyOnly: Bool) async {
        let config = configStore.current()
        let style = config.effectiveStyle(forApp: targetApp)
        var rawText = "", waited = 0.0, transcribeTime = 0.0, cleanupTime = 0.0, modelUse = ""

        func finish(_ text: String, _ outcome: Outcome, pasted: TimeInterval? = nil) {
            let report = Report(text: text, rawText: rawText, outcome: outcome, style: style, audioDuration: recording.duration, tail: recording.tail,
                                waitedForModel: waited, transcribe: transcribeTime, cleanup: cleanupTime,
                                releaseToPaste: pasted.map { $0 - releasedAt }, residentMB: Memory.megabytes().resident, modelUse: modelUse)
            Log.info(Self.logLine(report, includeText: config.debug.logTranscripts))
            if config.debug.keepAudio && outcome != .blockedPasswordField { Self.keepAudio(recording.samples) }      // never the audio of a password field
            status(.finished(report))
        }

        // A password field: the words are not even transcribed. Nothing is pasted, copied, remembered or logged, and no audio is kept.
        if secureInput() { finish("", .blockedPasswordField); return }

        guard recording.voicedDuration >= Defaults.minVoicedDuration else { finish("", .noSpeech); return }

        status(.transcribing)
        let waitStart = ProcessInfo.processInfo.systemUptime
        let mustWait = !isReady
        if mustWait { status(.waitingForModel) }   // the overlay shows "Loading model" instead of "Cleaning up"
        do { try await loadTask?.value } catch { finish("", .failed("model not available: \(error)")); return }
        waited = ProcessInfo.processInfo.systemUptime - waitStart
        if mustWait { status(.transcribing) }

        let t0 = ProcessInfo.processInfo.systemUptime
        do { rawText = try await transcriber.transcribe(samples: recording.samples) } catch { finish("", .failed("\(error)")); return }
        transcribeTime = ProcessInfo.processInfo.systemUptime - t0
        readyLock.lock(); lastSpeechUse = ProcessInfo.processInfo.systemUptime; readyLock.unlock()
        guard !rawText.isEmpty else { finish("", .noSpeech); return }

        // The rules (fillers, dictionary, snippets, spoken formatting) always run. Whether the cleanup model runs after them depends on the
        // style: Exact never, Polished always, Natural only for text that is likely to need it. See ModelPlan and NaturalPolicy.
        let prepared = TextProcessing.prepare(rawText, config: config)
        var text = prepared.raw
        var skipped: String?
        let decision = ModelPlan.decide(style: style, text: prepared.raw, longTextWords: config.cleanup.naturalLongTextWords, model: modelState)
        modelUse = decision.label
        if decision.usesModel {
            var ready = cleanerIsReady
            if !ready {
                // The model was freed (or is still loading). Wait a little for it rather than paste untidy text.
                let w0 = ProcessInfo.processInfo.systemUptime
                status(.waitingForModel)
                ready = await waitForCleaner(config: config)
                waited += ProcessInfo.processInfo.systemUptime - w0
                status(.transcribing)
            }
            if ready, let cleaner {
                let t1 = ProcessInfo.processInfo.systemUptime
                // A long dictation goes to the model in pieces (see CleanupRunner); nothing said is ever lost.
                let outcome = await CleanupRunner.run(prepared, cleaner: cleaner, style: style, terms: config.dictionary.map(\.term),
                                                      timeout: config.cleanup.timeoutSeconds)
                cleanupTime = ProcessInfo.processInfo.systemUptime - t1
                readyLock.lock(); lastModelUse = ProcessInfo.processInfo.systemUptime; readyLock.unlock()
                if let cleaned = outcome.text { text = cleaned; skipped = outcome.summary } else { skipped = outcome.problems.first }
            } else {
                skipped = "the cleanup model wasn't ready in time"
            }
        }
        let pastedOutcome: Outcome = skipped.map { .pastedWithoutCleanup($0) } ?? .pasted

        // Whenever the text goes on the clipboard instead of into the app, this one path does it. The reasons differ: the owner asked for
        // it (copy modifier), or pasting would be wrong or impossible (the app changed, no Accessibility, a password field).
        func copyInstead(_ outcome: Outcome) async {
            // A copy the owner asked for is left visible to clipboard managers; a fallback copy is marked temporary.
            await MainActor.run { output.copy(text, transient: outcome != .copied) }
            finish(text, outcome, pasted: outcome == .copied ? ProcessInfo.processInfo.systemUptime : nil)
        }
        // Checked again now: focus may have moved into a password field while the words were being processed. This covers a deliberate copy too.
        if secureInput() { rawText = ""; finish("", .blockedPasswordField); return }
        if copyOnly { await copyInstead(.copied); return }

        // Decide whether pasting is safe. If not, the text goes on the clipboard instead.
        let frontNow = await MainActor.run { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
        if frontNow != targetApp {
            Log.info("app changed: pressed in \(targetApp ?? "nil"), now \(frontNow ?? "nil")")
            await copyInstead(.copiedAppChanged); return
        }
        guard Permissions.accessibility else { await copyInstead(.copiedNoAccessibility); return }
        let posted = await MainActor.run { output }.paste(text)
        finish(text, pastedOutcome, pasted: posted)
    }

    private func status(_ s: Status) { DispatchQueue.main.async { self.onStatus?(s) } }
}

extension DictationPipeline.Outcome {
    /// Whether the text of this dictation may be remembered for "Copy last dictation" (and written to history).
    /// Never for a password field, and there is nothing to remember when no speech was heard or it failed.
    public var isStorable: Bool {
        switch self {
        case .pasted, .pastedWithoutCleanup, .copied, .copiedAppChanged, .copiedNoAccessibility: return true
        case .noSpeech, .failed, .blockedPasswordField: return false
        }
    }
}

/// Where a dictation's text goes. The real one is the clipboard and a simulated Cmd-V; tests use one that only records.
public protocol TextOutput {
    @MainActor func paste(_ text: String) async -> TimeInterval
    @MainActor func copy(_ text: String, transient: Bool)
}

public struct SystemTextOutput: TextOutput {
    public init() {}
    @MainActor public func paste(_ text: String) async -> TimeInterval { await Paster.paste(text) }
    @MainActor public func copy(_ text: String, transient: Bool) { Paster.copyOnly(text, transient: transient) }
}
