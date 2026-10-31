import AVFoundation
import Foundation

/// Captures the microphone and writes 16 kHz mono 16-bit WAV, resampling at capture.
public final class AudioRecorder {
    public struct Result {
        /// The recording as 16 kHz mono samples (-1...1). Kept in memory only; nothing is written to disk unless "Save audio" is on.
        public let samples: [Float]
        public let duration: TimeInterval
        public let peakDBFS: Double
        /// Total length of 20 ms windows loud enough to count as speech (simple energy gate).
        public let voicedDuration: TimeInterval
        /// Key press to first audio written.
        public let startLatency: TimeInterval?
        /// stop() call to file closed.
        public let stopLatency: TimeInterval
        /// How long recording continued after the key was released (set by the controller).
        public var tail: TimeInterval = 0

        public init(samples: [Float], duration: TimeInterval, peakDBFS: Double, voicedDuration: TimeInterval, startLatency: TimeInterval? = nil,
                    stopLatency: TimeInterval = 0, tail: TimeInterval = 0) {
            self.samples = samples; self.duration = duration; self.peakDBFS = peakDBFS; self.voicedDuration = voicedDuration
            self.startLatency = startLatency; self.stopLatency = stopLatency; self.tail = tail
        }
    }

    public enum RecorderError: Error { case noInputDevice, converter, file(Error) }

    /// Earlier versions wrote each recording to a temporary file; this folder is cleared at launch in case one was left behind.
    private static let leftoverDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent(AppIdentity.name, isDirectory: true)

    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Defaults.sampleRate, channels: 1, interleaved: true)!
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private var frames: AVAudioFramePosition = 0
    private var peak: Int16 = 0
    private var voicedSamples = 0
    private var lastVoicedAt: TimeInterval = 0
    private let spectrum = SpectrumAnalyzer()
    private var requestedAt: TimeInterval = 0
    private var firstAudioAt: TimeInterval?

    public init() {}

    public var isRecording: Bool { engine != nil }

    /// Latest 16 band levels (0...1) for the overlay; all zeros when not recording.
    public func spectrumLevels() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return engine == nil ? [Float](repeating: 0, count: SpectrumAnalyzer.bandCount) : spectrum.levels
    }

    /// Time since the last 20 ms window that counted as speech (since recording began if there hasn't been any).
    public func silenceDuration() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return ProcessInfo.processInfo.systemUptime - lastVoicedAt
    }

    public static func clearTemporaryFiles() {
        try? FileManager.default.removeItem(at: leftoverDirectory)
    }

    /// Writes samples as a 16 kHz mono 16-bit WAV (only used by the "Save audio" option).
    public static func writeWAV(_ samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Defaults.sampleRate, channels: 1, interleaved: true)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)), let out = buffer.int16ChannelData?[0] else { return }
        for (i, v) in samples.enumerated() { out[i] = Int16(clamping: Int((v * 32768).rounded())) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try file.write(from: buffer)
    }

    public func start() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw RecorderError.noInputDevice }
        guard let converter = AVAudioConverter(from: inFormat, to: target) else { throw RecorderError.converter }

        lock.lock()
        self.engine = engine; self.converter = converter
        requestedAt = ProcessInfo.processInfo.systemUptime
        spectrum.reset()
        samples.removeAll(keepingCapacity: false); samples.reserveCapacity(Int(Defaults.sampleRate) * 30)
        frames = 0; peak = 0; voicedSamples = 0; firstAudioAt = nil; lastVoicedAt = requestedAt
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            discard()
            throw error
        }
    }

    /// Stops capture and closes the file. `keep: false` deletes it.
    @discardableResult
    public func stop(keep: Bool = true) -> Result? {
        let stopStart = ProcessInfo.processInfo.systemUptime
        guard let engine else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        lock.lock()
        let samples = self.samples
        let frames = self.frames
        let peak = self.peak
        let voiced = voicedSamples
        let first = firstAudioAt
        let requested = requestedAt
        converter = nil
        self.engine = nil
        self.samples = []
        lock.unlock()

        guard keep else { return nil }
        let dbfs = peak == 0 ? -120 : 20 * log10(Double(peak) / 32768)
        return Result(
            samples: samples,
            duration: Double(frames) / Defaults.sampleRate,
            peakDBFS: dbfs,
            voicedDuration: Double(voiced) / Defaults.sampleRate,
            startLatency: first.map { $0 - requested },
            stopLatency: ProcessInfo.processInfo.systemUptime - stopStart)
    }

    private func discard() {
        lock.lock()
        engine = nil; converter = nil; samples = []
        lock.unlock()
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return }
        if firstAudioAt == nil { firstAudioAt = ProcessInfo.processInfo.systemUptime }
        frames += AVAudioFramePosition(out.frameLength)
        if let data = out.int16ChannelData?[0] {
            let n = Int(out.frameLength)
            samples.append(contentsOf: UnsafeBufferPointer(start: data, count: n).lazy.map { Float($0) / 32768 })
            // The first moments after the engine starts contain a thump that isn't the user's voice, so keep it off the display.
            if let first = firstAudioAt, ProcessInfo.processInfo.systemUptime - first > 0.12 { spectrum.push(data, count: n) }
            for i in 0..<n { peak = max(peak, Int16(clamping: abs(Int(data[i])))) }
            let window = Int(Defaults.sampleRate * 0.02)
            let threshold = 32768 * pow(10, Defaults.speechRMSThresholdDBFS / 20)
            var start = 0
            while start + window <= n {
                var sum = 0.0
                for i in start..<(start + window) { let v = Double(data[i]); sum += v * v }
                if (sum / Double(window)).squareRoot() > threshold { voicedSamples += window; lastVoicedAt = ProcessInfo.processInfo.systemUptime }
                start += window
            }
        }
    }
}
