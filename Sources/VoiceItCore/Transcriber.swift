import FluidAudio
import Foundation

/// The speech step, kept behind a small interface so the model can be swapped.
public protocol Transcriber: AnyObject {
    func load() async throws
    /// 16 kHz mono samples in memory: what the app uses, so a dictation's audio never has to be written to disk.
    func transcribe(samples: [Float]) async throws -> String
    /// One short throwaway pass, so the next real transcription doesn't pay the cost of waking the Neural Engine after a pause.
    func warmUp() async
    /// An audio file (the test harness).
    func transcribe(url: URL) async throws -> String
}

/// Parakeet TDT 0.6B v2 on the Neural Engine through FluidAudio, loaded from a local folder with downloads switched off.
public final class FluidAudioTranscriber: Transcriber {
    public enum TranscriberError: Error, CustomStringConvertible {
        case notLoaded
        case modelsMissing(URL)
        public var description: String {
            switch self {
            case .notLoaded: return "model not loaded"
            case .modelsMissing(let u): return "model files not found at \(u.path); run scripts/setup-models.sh"
            }
        }
    }

    private let directory: URL
    private var manager: AsrManager?

    public init(modelsDirectory: URL = Paths.parakeetModels) { self.directory = modelsDirectory }

    public func load() async throws {
        // Runtime must never touch the network: any download path now throws instead.
        ModelHub.offlineMode = true
        guard AsrModels.modelsExist(at: directory, version: .v2) else { throw TranscriberError.modelsMissing(directory) }
        let models = try await AsrModels.load(from: directory, version: .v2)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
        // One throwaway pass so the first real dictation doesn't pay any first-call cost.
        var state = TdtDecoderState.make()
        _ = try? await manager.transcribe([Float](repeating: 0, count: 16_000), decoderState: &state)
    }

    public func warmUp() async {
        guard let manager else { return }
        var state = TdtDecoderState.make()
        _ = try? await manager.transcribe([Float](repeating: 0, count: 8_000), decoderState: &state)      // half a second of silence
    }

    public func transcribe(samples: [Float]) async throws -> String {
        guard let manager else { throw TranscriberError.notLoaded }
        var state = TdtDecoderState.make()
        let result = try await manager.transcribe(samples, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func transcribe(url: URL) async throws -> String {
        guard let manager else { throw TranscriberError.notLoaded }
        var state = TdtDecoderState.make()
        let result = try await manager.transcribe(url, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
