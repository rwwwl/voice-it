import AVFoundation
// voice-it-harness: runs the transcribe step over WAV fixtures with no microphone, and prints timings.
// Usage: voice-it-harness [file.wav ...]   (defaults to fixtures/audio/*.wav)
// Models: Application Support/Voice It/models, or VOICEIT_MODELS_DIR.
import VoiceItCore
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)   // flush every line, so output survives a crash
func ms(_ seconds: Double) -> String { String(format: "%.0f ms", seconds * 1000) }
func now() -> Double { ProcessInfo.processInfo.systemUptime }

import AppKit

/// The cleanup samples assume the project's example vocabulary (the default for everyone is empty).
func sampleConfig() -> Config { var c = Config(); c.dictionary = Config.exampleDictionary; return c }
if CommandLine.arguments.dropFirst().first == "--clipboard-test" {
    // Checks the copy-to-clipboard fallback without pasting anywhere, then puts the user's clipboard back.
    let pb = NSPasteboard.general
    let before = pb.string(forType: .string)
    await MainActor.run { Paster.copyOnly("voice-it clipboard test") }
    let after = pb.string(forType: .string)
    print("clipboard after copyOnly: \(after.map { "\"\($0)\"" } ?? "nil") -> \(after == "voice-it clipboard test" ? "OK" : "FAILED")")
    print("types on clipboard: \(pb.types?.map(\.rawValue) ?? [])")
    pb.clearContents()
    if let before { pb.setString(before, forType: .string) }
    exit(after == "voice-it clipboard test" ? 0 : 1)
}

if CommandLine.arguments.dropFirst().first == "--selftest-tail" {
    // Usage: --selftest-tail <holdSeconds> ["text for say"]. Needs mic access for this process; the signed app has it (see the app's --selftest-tail).
    let args = Array(CommandLine.arguments.dropFirst(2))
    print(TailSelfTest.run(holdFor: Double(args.first ?? "1.5") ?? 1.5, say: args.count > 1 ? args[1] : nil))
    exit(0)
}

if CommandLine.arguments.dropFirst().first == "--cleanup" {
    // Usage: --cleanup <model directory> [fixtures/cleanup]   Runs every NN-name.<natural|polished|exact>.raw.txt (exact ones use no model: the rules only) through the cleanup model.
    let args = Array(CommandLine.arguments.dropFirst(2))
    guard let modelPath = args.first else { print("usage: --cleanup <model dir> [samples dir]"); exit(1) }
    let samples = URL(fileURLWithPath: args.count > 1 ? args[1] : "fixtures/cleanup")
    let terms = ["Parakeet", "FluidAudio", "Neural Engine", "Xcode"]
    let cleaner = MLXCleaner(modelDirectory: URL(fileURLWithPath: modelPath))
    if ProcessInfo.processInfo.environment["CLEANUP_NO_CACHE"] != nil { cleaner.usePrefixCache = false; print("(prefix cache off)") }
    if let file = ProcessInfo.processInfo.environment["CLEANUP_SYSTEM_FILE"], let custom = try? String(contentsOfFile: file, encoding: .utf8) {
        // Prompt experiments. {tone} and {terms} are filled in.
        cleaner.promptBuilder = { style, terms in custom.replacingOccurrences(of: "{tone}", with: style.rawValue).replacingOccurrences(of: "{terms}", with: terms.joined(separator: ", ")) }
        print("(using system prompt from \(file))")
    }
    if let wrap = ProcessInfo.processInfo.environment["CLEANUP_USER_TEMPLATE"] {
        cleaner.userBuilder = { wrap.replacingOccurrences(of: "{text}", with: $0) }
        print("(wrapping transcript: \(wrap))")
    }
    let t0 = now()
    do { try await cleaner.load() } catch { print("load failed: \(error)"); exit(1) }
    let loaded = Memory.megabytes()
    print("model: \(URL(fileURLWithPath: modelPath).lastPathComponent)\nload: \(ms(now() - t0))   footprint \(Int(loaded.footprint)) MB, resident \(Int(loaded.resident)) MB\n")
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: samples.path)) ?? []).filter { $0.hasSuffix(".raw.txt") }.sorted()
    func read(_ name: String) -> String { ((try? String(contentsOf: samples.appendingPathComponent(name), encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    func style(of file: String) -> Style { Style(lenient: file.split(separator: ".").dropFirst().first.map(String.init) ?? "") ?? .natural }
    // Warm-up pass, not counted: first generation pays one-time costs.
    for s in [Style.natural, .polished] { await cleaner.warmUp(style: s, terms: terms) }   // also builds each style's prefix cache
    var totals: [Double] = [], prefills: [Double] = [], decodeRates: [Double] = []
    for file in files {
        let base = String(file.dropLast(".raw.txt".count))
        let raw = read(file), target = read(base + ".clean.txt")
        do {
            let style = style(of: file)
            if style == .exact {
                let ruled = TextProcessing.withoutModel(raw, config: sampleConfig())
                print("\(base)  [exact style: rules only, no model]\n  raw:    \(raw)\n  got:    \(ruled)\n  target: \(target)\n")
                continue
            }
            let r = try await cleaner.clean(raw, style: style, terms: terms)
            totals.append(r.totalSeconds); prefills.append(r.promptSeconds)
            if r.generateSeconds > 0 { decodeRates.append(Double(r.generatedTokens) / r.generateSeconds) }
            print("\(base)  [\(ms(r.totalSeconds)) total | prefill \(ms(r.promptSeconds)) for \(r.promptTokensRead) of \(r.promptTokens) tok | \(r.generatedTokens) tok out in \(ms(r.generateSeconds))]")
            print("  raw:    \(raw)\n  got:    \(r.text)\n  target: \(target)\(r.text == target ? "   (exact match)" : "")\n")
        } catch { print("\(base): FAILED \(error)\n") }
    }
    let end = Memory.megabytes()
    func avg(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
    print("SUMMARY \(URL(fileURLWithPath: modelPath).lastPathComponent): mean total \(ms(avg(totals))), max \(ms(totals.max() ?? 0)), mean prefill \(ms(avg(prefills))), mean decode \(Int(avg(decodeRates))) tok/s, resident \(Int(end.resident)) MB, footprint \(Int(end.footprint)) MB")
    exit(0)
}

if CommandLine.arguments.dropFirst().first == "--vocab-bench" {
    // Usage: --vocab-bench <model dir> N [N ...]   How the vocabulary size affects cleanup: the prompt grows with every term, and each
    // change to the list makes the model re-read it once. Reports, per size: prompt tokens, the one-off re-read (warm-up), the cleanup
    // time on the fixture samples afterwards, and the time the rules take (heard-as replacements).
    let args = Array(CommandLine.arguments.dropFirst(2))
    guard let modelPath = args.first, args.count > 1 else { print("usage: --vocab-bench <model dir> N [N ...]"); exit(1) }
    let sizes = args.dropFirst().compactMap(Int.init)
    let syllables = ["bra", "vel", "mo", "tix", "dor", "lan", "ke", "shu", "pir", "gon", "fa", "zen", "qui", "no", "rav", "sel", "tum", "or", "ba", "lix"]
    func name(_ i: Int) -> String {
        var n = i + 7, out = ""
        for _ in 0..<3 { out += syllables[n % syllables.count]; n = n / syllables.count + i % 5 + 1 }
        return out.prefix(1).uppercased() + out.dropFirst()
    }
    let samplesDir = URL(fileURLWithPath: "fixtures/cleanup")
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: samplesDir.path)) ?? []).filter { $0.hasSuffix(".raw.txt") }.sorted()
    let texts = files.map { (try? String(contentsOf: samplesDir.appendingPathComponent($0), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    let cleaner = MLXCleaner(modelDirectory: URL(fileURLWithPath: modelPath))
    do { try await cleaner.load() } catch { print("load failed: \(error)"); exit(1) }
    await cleaner.warmUp(style: .natural, terms: ["Warm"])      // one-time start-up costs, not counted
    print("terms | prompt chars | re-read after an edit | cleanup per sample (mean / max) | rules per dictation (N corrections)")
    for n in sizes {
        let terms = (0..<n).map(name)
        let system = CleanupPrompt.system(style: .natural, terms: terms)
        let w0 = now()
        await cleaner.warmUp(style: .natural, terms: terms)
        let rewarm = now() - w0
        var times: [Double] = []
        for t in texts where !t.isEmpty {
            let t0 = now()
            _ = try? await cleaner.clean(t, style: .natural, terms: terms)
            times.append(now() - t0)
        }
        var config = Config()
        config.dictionary = terms.map { Config.DictionaryEntry(term: $0, heardAs: [$0.lowercased() + " x"]) }
        let r0 = now()
        for _ in 0..<20 { _ = TextProcessing.prepare(texts.first ?? "", config: config) }
        let rules = (now() - r0) / 20
        let mean = times.reduce(0, +) / Double(max(1, times.count))
        print("\(n) | \(system.count) | \(ms(rewarm)) | \(ms(mean)) / \(ms(times.max() ?? 0)) | \(ms(rules))")
    }
    exit(0)
}

if CommandLine.arguments.dropFirst().first == "--pipeline-text" {
    // Usage: --pipeline-text <model dir> <style: natural|polished> "<raw transcript>" ...   Runs what the app does between transcription and paste, minus the paste.
    // CLEANUP_TIMEOUT overrides the timeout (seconds) to test the fallback.
    let args = Array(CommandLine.arguments.dropFirst(2))
    guard args.count >= 3 else { print("usage: --pipeline-text <model dir> <style> \"text\" ..."); exit(1) }
    var config = sampleConfig()
    config.snippets = [Config.Snippet(trigger: "my email address", expansion: "hello@example.com")]
    if let t = ProcessInfo.processInfo.environment["CLEANUP_TIMEOUT"], let v = Double(t) { config.cleanup.timeoutSeconds = v }
    let style = Style(lenient: args[1]) ?? .natural
    let terms = config.dictionary.map(\.term)
    let cleaner = MLXCleaner(modelDirectory: URL(fileURLWithPath: args[0]))
    do { try await cleaner.load() } catch { print("load failed: \(error)"); exit(1) }
    await cleaner.warmUp(style: style, terms: terms)
    var firstItem = true
    let firstTimeout = ProcessInfo.processInfo.environment["CLEANUP_TIMEOUT_FIRST"].flatMap(Double.init)
    for raw in args.dropFirst(2) {
        let timeout = (firstItem ? firstTimeout : nil) ?? config.cleanup.timeoutSeconds
        firstItem = false
        print("heard:    \(raw)")
        let prepared = TextProcessing.prepare(raw, config: config)
        print("to model: \(prepared.forModel.replacingOccurrences(of: "\n", with: "\\n"))")
        let t0 = now()
        let outcome = await CleanupRunner.run(prepared, cleaner: cleaner, style: style, terms: terms, timeout: timeout)
        let elapsed = now() - t0
        let final = outcome.text ?? prepared.raw
        let note = outcome.summary.map { "\($0) (\(ms(elapsed)))" } ?? "cleaned in \(ms(elapsed)) as \(outcome.pieces) piece(s)"
        print("result:   \(final.replacingOccurrences(of: "\n", with: "\\n"))   <- \(note)\n")
    }
    try? await Task.sleep(nanoseconds: 1_500_000_000)   // let any abandoned generation finish before the process exits
    exit(0)
}

if CommandLine.arguments.dropFirst().first == "--logging-test" {
    // Checks the transcript-logging option and that a short or older config.json still loads.
    let report = DictationPipeline.Report(text: "Hello Sam, see you Friday.", rawText: "um hello sam see you friday", outcome: .pasted, style: .natural,
                                          audioDuration: 3.2, tail: 0.12, waitedForModel: 0, transcribe: 0.14, cleanup: 0.31, releaseToPaste: 0.62, residentMB: 2400)
    print("debug off:", DictationPipeline.logLine(report, includeText: false))
    print("debug on: ", DictationPipeline.logLine(report, includeText: true))
    let dec = JSONDecoder()
    func tryDecode(_ label: String, _ json: String) {
        do { let c = try dec.decode(Config.self, from: Data(json.utf8)); print("\(label): loads, logTranscripts=\(c.debug.logTranscripts), model=\(c.cleanup.model), timeout=\(c.cleanup.timeoutSeconds), \(c.dictionary.count) dictionary entries, style \(c.style.rawValue), \(c.appStyles.count) app styles") }
        catch { print("\(label): FAILED \(error)") }
    }
    tryDecode("empty object      ", "{}")
    tryDecode("only cleanup.model", #"{"cleanup": {"model": "x"}}"#)
    tryDecode("debug turned on   ", #"{"debug": {"logTranscripts": true}}"#)
    if let data = try? Data(contentsOf: ConfigStore.url), let c = try? dec.decode(Config.self, from: data) { print("your current config.json: loads, logTranscripts=\(c.debug.logTranscripts), model=\(c.cleanup.model)") } else { print("your current config.json: FAILED or missing") }
    exit(0)
}

if CommandLine.arguments.dropFirst().first == "--pipeline-audio" {
    // Usage: --pipeline-audio <exact|natural|polished> <keepReady|freeWhenIdle> [--idle-test] [--gap N [--no-warmup]] file.wav ...
    // --gap N waits N seconds before each file, then does what the app does at key-down (the speech warm-up) and lets half a second pass, as a
    // real hold would, before the recording arrives. --no-warmup skips the key-down step, to show what the pause costs.
    // Runs real dictations through the whole pipeline (transcribe, decide, load, clean up) with the result copied, never pasted.
    // Reports, for each: whether the model was used and why, how long it waited, and the end-to-end time. --idle-test sets the idle time
    // to one minute, waits for the model to be freed, and runs the first file again to time a cold reload.
    let args = Array(CommandLine.arguments.dropFirst(2))
    guard args.count >= 3, let style = StyleChoice(lenient: args[0]), let memory = ModelMemory(lenient: args[1]) else { print("usage: --pipeline-audio <style> <memory> [--idle-test] file.wav ..."); exit(1) }
    let idleTest = args.contains("--idle-test")
    let gap = args.firstIndex(of: "--gap").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil }
    let files = args.dropFirst(2).enumerated().filter { !$0.element.hasPrefix("--") && Double($0.element) == nil }.map(\.element)
    var config = Config(); config.style = style; config.cleanup.memory = memory; config.cleanup.idleMinutes = 1
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voice-it-pipeline-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("config.json")
    try? JSONEncoder().encode(config).write(to: file)
    let store = ConfigStore(fileURL: file)
    let pipeline = DictationPipeline(transcriber: FluidAudioTranscriber(), cleaner: MLXCleaner(modelDirectory: config.cleanupModelDirectory), configStore: store)
    var ready = false
    var waiting: CheckedContinuation<DictationPipeline.Report, Never>?
    pipeline.onStatus = { status in
        switch status {
        case .modelReady: ready = true
        case .finished(let r): waiting?.resume(returning: r); waiting = nil
        default: break
        }
    }
    func footprint() -> String { "footprint \(Int(Memory.megabytes().footprint)) MB" }
    let start = now()
    pipeline.startLoading()
    while !ready { try? await Task.sleep(nanoseconds: 50_000_000) }
    print("style \(style.rawValue), cleanup model \(memory.rawValue): ready after \(ms(now() - start)), \(footprint())\n")
    func dictate(_ path: String) async {
        let url = URL(fileURLWithPath: path)
        guard let f = try? AVAudioFile(forReading: url), let buffer = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)), (try? f.read(into: buffer)) != nil else { print("\(path): can't read"); return }
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let recording = AudioRecorder.Result(samples: samples, duration: Double(samples.count) / 16_000, peakDBFS: -10, voicedDuration: Double(samples.count) / 16_000)
        if let gap {
            try? await Task.sleep(nanoseconds: UInt64(gap * 1e9))
            if !args.contains("--no-warmup") { pipeline.prepareForDictation(targetApp: nil) }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        let t0 = now()
        let r: DictationPipeline.Report = await withCheckedContinuation { c in
            waiting = c
            pipeline.enqueue(recording, releasedAt: ProcessInfo.processInfo.systemUptime, targetApp: nil, copyOnly: true)
        }
        print("\(url.deletingPathExtension().lastPathComponent): \(r.modelUse) | waited \(ms(r.waitedForModel)), transcribe \(ms(r.transcribe)), cleanup \(ms(r.cleanup)), end to end \(ms(now() - t0)) | \(footprint())")
        print("    \"\(r.text)\"")
    }
    for path in files { await dictate(path) }
    if idleTest, let first = files.first {
        print("\nwaiting 70 s for the idle time to pass…")
        try? await Task.sleep(nanoseconds: 70_000_000_000)
        pipeline.syncCleanupModel()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        print("after the idle check: loaded \(pipeline.cleanupModelReady), \(footprint())")
        await dictate(first)
    }
    exit(0)
}

if CommandLine.arguments.dropFirst().first == "--natural-policy" {
    // Usage: --natural-policy <model dir> [fixtures/cleanup] [--log path]
    // Checks Natural's rule for when to use the model against what the model really does. Each sample (a fixture, or a dictation from the
    // log that has its words in it) goes through the rules, then through the policy, and through the model; "needed" means the model
    // changed the words (not just punctuation or capitals). Prints the four counts and every case where the policy skipped a needed one.
    let args = Array(CommandLine.arguments.dropFirst(2))
    guard let modelPath = args.first else { print("usage: --natural-policy <model dir> [samples dir] [--log path]"); exit(1) }
    let logIndex = args.firstIndex(of: "--log")
    let dirArg = args.enumerated().dropFirst().first { !$0.element.hasPrefix("--") && $0.offset != (logIndex ?? -2) + 1 }?.element
    let dir = URL(fileURLWithPath: dirArg ?? "fixtures/cleanup")
    let logPath = args.firstIndex(of: "--log").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    let config = sampleConfig()
    var samples: [(name: String, raw: String)] = []
    for f in ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter({ $0.hasSuffix(".natural.raw.txt") }).sorted() {
        samples.append((String(f.dropLast(".raw.txt".count)), ((try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)))
    }
    if let logPath, let log = try? String(contentsOfFile: logPath, encoding: .utf8) {
        for (i, line) in log.split(separator: "\n").enumerated() {
            guard let r = line.range(of: " | raw: \""), let e = line.range(of: "\" | final: \"", range: r.upperBound..<line.endIndex) else { continue }
            let raw = String(line[r.upperBound..<e.lowerBound])
            if !raw.isEmpty { samples.append(("log line \(i + 1)", raw)) }
        }
    }
    let cleaner = MLXCleaner(modelDirectory: URL(fileURLWithPath: modelPath))
    do { try await cleaner.load() } catch { print("load failed: \(error)"); exit(1) }
    await cleaner.warmUp(style: .natural, terms: config.dictionary.map(\.term))
    func words(_ s: String) -> [String] { NaturalPolicy.tokens(s) }
    var counts: [String: Int] = [:], missed: [String] = []
    for sample in samples {
        let prepared = TextProcessing.prepare(sample.raw, config: config)
        let reason = NaturalPolicy.reason(for: prepared.raw, longTextWords: config.cleanup.naturalLongTextWords)
        let outcome = await CleanupRunner.run(prepared, cleaner: cleaner, style: .natural, terms: config.dictionary.map(\.term), timeout: 10)
        let needed = outcome.text.map { words($0) != words(prepared.raw) } ?? false
        counts[(needed ? "model needed" : "model not needed") + ", " + (reason == nil ? "skipped" : "called"), default: 0] += 1
        if needed && reason == nil { missed.append("\(sample.name): \(prepared.raw)  ->  \(outcome.text ?? "")") }
    }
    print("\(samples.count) samples")
    for k in counts.keys.sorted() { print("  \(k): \(counts[k]!)") }
    for m in missed { print("  MISSED \(m)") }
    exit(0)
}

if CommandLine.arguments.dropFirst().first == "--requirements" {
    // Shows the requirements check for this Mac, or for a pretend one:
    // --requirements [--memory-gb N] [--free-gb N] [--macos 14.5] [--intel] [--models speech|cleanup]
    let args = Array(CommandLine.arguments.dropFirst(2))
    func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    var facts = Requirements.currentFacts(at: Paths.applicationSupport)
    if let m = value("--memory-gb").flatMap(UInt64.init) { facts.memoryBytes = m << 30 }
    if let d = value("--free-gb").flatMap(Double.init) { facts.freeDiskBytes = UInt64(d * 1_000_000_000) }
    if let v = value("--macos") { let p = v.split(separator: ".").compactMap { Int($0) }; facts.macOS = OSVersion(p.first ?? 0, p.count > 1 ? p[1] : 0, p.count > 2 ? p[2] : 0) }
    if args.contains("--intel") { facts.isAppleSilicon = false }
    let models: ModelSet = value("--models").map { $0.lowercased().hasPrefix("speech") ? .speechOnly : .withCleanup } ?? .withCleanup
    let report = Requirements.check(facts: facts, models: models)
    print("models: \(models.rawValue)   need \(ByteCountFormatter.string(fromByteCount: Int64(Requirements.requiredFreeBytes(for: models)), countStyle: .file)) free")
    for r in report.results { print("  [\(r.status.rawValue.uppercased())] \(r.item.rawValue): \(r.message)") }
    print("can continue: \(report.canContinue)   recommended models: \(report.recommendedModels.rawValue)")
    exit(report.canContinue ? 0 : 1)
}

var paths = Array(CommandLine.arguments.dropFirst())
if paths.isEmpty {
    let dir = "fixtures/audio"
    paths = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".wav") }.sorted().map { "\(dir)/\($0)" }
}
guard !paths.isEmpty else { print("no WAV files given and none in fixtures/audio"); exit(1) }

let transcriber = FluidAudioTranscriber()
let t0 = now()
do { try await transcriber.load() } catch { print("load failed: \(error)"); exit(1) }
let mem = Memory.megabytes()
print("model load: \(ms(now() - t0))   footprint \(Int(mem.footprint)) MB, resident \(Int(mem.resident)) MB   (offline mode on)\n")

for path in paths {
    let url = URL(fileURLWithPath: path)
    let name = url.deletingPathExtension().lastPathComponent
    let expectedURL = URL(fileURLWithPath: "fixtures/expected/\(name).txt")
    let expected = (try? String(contentsOf: expectedURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    let start = now()
    do {
        let text = try await transcriber.transcribe(url: url)
        print("\(name): \(ms(now() - start))")
        // The app transcribes from memory; it must give the same words as reading the file.
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let t1 = now()
        let fromMemory = try await transcriber.transcribe(samples: samples)
        print("  from memory: \(ms(now() - t1)), \(fromMemory == text ? "same text" : "DIFFERENT TEXT: \(fromMemory)")")
        // The Save audio option writes a WAV from the samples; reading it back must give the same audio.
        let saved = FileManager.default.temporaryDirectory.appendingPathComponent("voice-it-wav-check.wav")
        try AudioRecorder.writeWAV(samples, to: saved)
        let back = try AVAudioFile(forReading: saved), b2 = AVAudioPCMBuffer(pcmFormat: back.processingFormat, frameCapacity: AVAudioFrameCount(back.length))!
        try back.read(into: b2)
        let diff = (0..<min(samples.count, Int(b2.frameLength))).map { abs(samples[$0] - b2.floatChannelData![0][$0]) }.max() ?? 1
        print("  saved WAV: \(back.length == AVAudioFramePosition(samples.count) ? "same length" : "LENGTH DIFFERS"), largest sample difference \(diff)")
        try? FileManager.default.removeItem(at: saved)
        print("  got:      \(text)")
        if let expected { print("  expected: \(expected)") }
    } catch { print("\(name): FAILED \(error)") }
}
let end = Memory.megabytes()
print("\nfinal: footprint \(Int(end.footprint)) MB, resident \(Int(end.resident)) MB")
