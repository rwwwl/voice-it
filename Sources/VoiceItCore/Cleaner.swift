import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

public struct CleanupResult: Sendable {
    public let text: String
    public let promptTokens: Int
    /// Prompt tokens actually run through the model (the rest came from the cache).
    public let promptTokensRead: Int
    public let generatedTokens: Int
    public let promptSeconds: TimeInterval
    public let generateSeconds: TimeInterval
    public let totalSeconds: TimeInterval
}

/// The cleanup step, behind a small interface so the runtime can be swapped (for example for Ollama).
public protocol Cleaner: AnyObject {
    func load() async throws
    /// Releases the model and its memory. A later `load()` brings it back.
    func unload() async
    /// Whether the model's files are on disk (nothing is loaded to find out).
    var isInstalled: Bool { get }
    func clean(_ text: String, style: Style, terms: [String]) async throws -> CleanupResult
}

/// A 1 to 4B instruction model run in-process with MLX Swift, loaded from a local folder.
///
/// The instructions (system prompt, examples) are identical on every dictation, so their tokens are run through the
/// model once and the resulting KV cache is reused; only the transcript itself is processed per dictation.
public final class MLXCleaner: Cleaner, @unchecked Sendable {
    public enum CleanerError: Error, CustomStringConvertible {
        case notLoaded, modelsMissing(URL)
        public var description: String {
            switch self {
            case .notLoaded: return "cleanup model not loaded"
            case .modelsMissing(let u): return "cleanup model files not found at \(u.path)"
            }
        }
    }

    private struct Prefix { let system: String; let tokens: [Int]; let cache: [KVCache] }

    private let directory: URL
    private var container: ModelContainer?
    /// One cached prompt per style, replaced when the prompt changes (for example after the vocabulary is edited), so repeated edits
    /// never pile up old caches in memory. Only touched inside container.perform.
    private var prefixes: [String: Prefix] = [:]
    /// Builds the system prompt. Replaceable for prompt experiments.
    public var promptBuilder: (Style, [String]) -> String = CleanupPrompt.system
    /// Wraps the transcript in the user turn.
    public var userBuilder: (String) -> String = CleanupPrompt.userMessage
    /// Turn off to measure the cost of re-reading the instructions every time.
    public var usePrefixCache = true

    public init(modelDirectory: URL) { self.directory = modelDirectory }

    public var isInstalled: Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path) }

    public func unload() async {
        // Clear the prompt caches inside the model's own isolation, so a generation in progress isn't disturbed.
        if let c = container { await c.perform { _ in self.prefixes.removeAll() } }
        container = nil
        MLX.Memory.clearCache()  // MLX keeps freed GPU buffers around for reuse; hand them back
    }

    public func load() async throws {
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path) else {
            throw CleanerError.modelsMissing(directory)
        }
        MLX.Memory.cacheLimit = Defaults.mlxCacheLimitBytes
        container = try await LLMModelFactory.shared.loadContainer(from: directory, using: TransformersTokenizerLoader())
    }

    /// Reads the instructions for a style into the cache ahead of time, so the first dictation doesn't pay for it.
    public func warmUp(style: Style, terms: [String]) async {
        _ = try? await clean("hello", style: style, terms: terms)
    }

    public func clean(_ text: String, style: Style, terms: [String]) async throws -> CleanupResult {
        guard let container else { throw CleanerError.notLoaded }
        let start = ProcessInfo.processInfo.systemUptime
        let system = promptBuilder(style, terms)
        let user = userBuilder(text)
        // Output is never much longer than the input.
        let params = GenerateParameters(maxTokens: max(48, text.count / 2 + 32), temperature: 0)
        let useCache = usePrefixCache

        return try await container.perform { context in
            func tokens(_ transcript: String) throws -> [Int] {
                try context.tokenizer.applyChatTemplate(
                    messages: [["role": "system", "content": system], ["role": "user", "content": transcript]],
                    tools: nil, additionalContext: ["enable_thinking": false])   // no reasoning pass: it would blow the latency budget
            }
            let full = try tokens(user)

            var cache: [KVCache]? = nil
            var input = full
            if useCache {
                if self.prefixes[style.rawValue]?.system != system {
                    // The instructions are whatever two different transcripts have in common. Stop a few tokens early so a
                    // token that merges across the boundary can't make the cached part disagree with the real prompt.
                    let a = try tokens(self.userBuilder("a")), b = try tokens(self.userBuilder("b"))
                    var n = 0
                    while n < min(a.count, b.count), a[n] == b[n] { n += 1 }
                    let prefixTokens = Array(a[..<max(0, n - 2)])
                    let kv = context.model.newCache(parameters: params)
                    _ = context.model(MLXArray(prefixTokens).expandedDimensions(axis: 0), cache: kv)
                    eval(kv.flatMap { $0.state })
                    self.prefixes[style.rawValue] = Prefix(system: system, tokens: prefixTokens, cache: kv)
                }
                if let prefix = self.prefixes[style.rawValue], prefix.system == system, full.starts(with: prefix.tokens) {
                    cache = prefix.cache.map { $0.copy() }
                    input = Array(full[prefix.tokens.count...])
                } else {
                    Log.info("prompt cache mismatch; reading the full prompt")
                }
            }

            var output = ""
            var info: GenerateCompletionInfo?
            let stream = try generate(input: LMInput(tokens: MLXArray(input)), cache: cache, parameters: params, context: context)
            for await item in stream {
                switch item {
                case .chunk(let s): output += s
                case .info(let i): info = i
                default: break
                }
            }
            return CleanupResult(
                text: output.trimmingCharacters(in: .whitespacesAndNewlines),
                promptTokens: full.count,
                promptTokensRead: input.count,
                generatedTokens: info?.generationTokenCount ?? 0,
                promptSeconds: info?.promptTime ?? 0,
                generateSeconds: info?.generateTime ?? 0,
                totalSeconds: ProcessInfo.processInfo.systemUptime - start)
        }
    }
}

/// Adapts swift-transformers' tokenizer to MLXLMCommon, loading from a local folder (no network).
struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(try await AutoTokenizer.from(modelFolder: directory))
    }
}

private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer
    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
