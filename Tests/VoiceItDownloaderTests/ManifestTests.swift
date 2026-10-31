import CryptoKit
import Foundation
import Testing
import VoiceItLogic
@testable import VoiceItDownloader

enum TestSupport {
    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    /// A deterministic, not very compressible blob.
    static func blob(_ n: Int, seed: UInt8 = 1) -> Data {
        var x = UInt32(seed) &* 2654435761 | 1
        return Data((0..<n).map { _ in x = x &* 1664525 &+ 1013904223; return UInt8(truncatingIfNeeded: x >> 24) })
    }

    static func model(id: String = "cleanup", files: [String: Data], destination: String = "group/model") -> ModelManifest.Model {
        ModelManifest.Model(id: id, name: "Test model", repo: "owner/name", revision: String(repeating: "a", count: 40), licence: "MIT", destination: destination,
                            files: files.keys.sorted().map { ModelManifest.File(path: $0, sha256: sha(files[$0]!), size: Int64(files[$0]!.count)) })
    }

    static func tempRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("voice-it-dl-\(UUID().uuidString)", isDirectory: true) }
}

@Suite("Model manifest")
struct ManifestTests {
    func manifest() throws -> ModelManifest { try ModelManifest.load(from: TestSupport.repoRoot.appendingPathComponent("Resources/models-manifest.json")) }

    @Test func theShippedManifestIsValidAndListsBothModels() throws {
        let m = try manifest()
        #expect(m.models.map(\.id) == ["speech", "cleanup"])
        #expect(m.model("speech")?.licence == "CC-BY-4.0" && m.model("cleanup")?.licence == "Apache-2.0")
    }

    @Test func itAgreesWithTheSizesTheRequirementsCheckUses() throws {
        let m = try manifest()
        #expect(m.model("speech")?.totalBytes == Int64(ModelSizes.speech))
        #expect(m.model("cleanup")?.totalBytes == Int64(ModelSizes.cleanup))
    }

    @Test func itPutsTheFilesWhereTheAppLooksForThem() throws {
        let m = try manifest()
        #expect(m.model("speech")?.destination == Paths.parakeetModels.lastPathComponent)
        #expect(Paths.applicationSupport.appendingPathComponent("models/" + (m.model("cleanup")?.destination ?? "?")).path == Config().cleanupModelDirectory.path)
    }

    @Test func everyFileComesFromAPinnedRevisionOnAnAllowedHost() throws {
        for model in try manifest().models {
            for file in model.files {
                let url = model.url(for: file)
                #expect(DownloadPolicy.isAllowed(url) && url.absoluteString.contains("/resolve/\(model.revision)/"), "\(url)")
            }
        }
    }

    @Test func aPathThatCouldLeaveTheModelsFolderIsRefused() {
        for bad in ["../x", "a/../x", "/etc/passwd", "a//b", "./x", "a\\b", "c:x", ""] {
            let model = ModelManifest.Model(id: "m", name: "n", repo: "o/r", revision: String(repeating: "a", count: 40), licence: "MIT", destination: "d",
                                            files: [.init(path: bad, sha256: String(repeating: "0", count: 64), size: 1)])
            #expect(throws: ModelManifest.ManifestError.self, "\(bad)") { try ModelManifest(models: [model]).validate() }
        }
        let evilDestination = ModelManifest.Model(id: "m", name: "n", repo: "o/r", revision: String(repeating: "a", count: 40), licence: "MIT", destination: "../d",
                                                  files: [.init(path: "x", sha256: String(repeating: "0", count: 64), size: 1)])
        #expect(throws: ModelManifest.ManifestError.self) { try ModelManifest(models: [evilDestination]).validate() }
    }

    @Test func aMalformedEntryIsRefused() {
        func check(revision: String = String(repeating: "a", count: 40), sha: String = String(repeating: "0", count: 64), size: Int64 = 1, repo: String = "o/r") -> Bool {
            let m = ModelManifest.Model(id: "m", name: "n", repo: repo, revision: revision, licence: "MIT", destination: "d", files: [.init(path: "x", sha256: sha, size: size)])
            return (try? ModelManifest(models: [m]).validate()) != nil
        }
        #expect(check())
        #expect(!check(revision: "main"))                       // must be a pinned commit, not a moving name
        #expect(!check(revision: String(repeating: "A", count: 40)))
        #expect(!check(sha: String(repeating: "g", count: 64)))
        #expect(!check(sha: "abc"))
        #expect(!check(size: 0))
        #expect(!check(repo: "no-slash"))
        #expect(!check(repo: "o/r/../x"))
    }

    @Test func onlyHuggingFaceOverHttpsIsAllowed() {
        for ok in ["https://huggingface.co/o/r/resolve/abc/x", "https://us.aws.cdn.hf.co/repos/x", "https://cas-bridge.xethub.hf.co/y", "https://hf.co/x", "https://cdn-lfs.huggingface.co/z"] {
            #expect(DownloadPolicy.isAllowed(URL(string: ok)!), "\(ok)")
        }
        for bad in ["http://huggingface.co/x", "https://example.com/x", "https://huggingface.co.evil.com/x", "https://evilhf.co/x", "https://nothf.co/x",
                    "https://huggingface.co@evil.com/x", "ftp://huggingface.co/x", "file:///etc/passwd", "https://user:pw@huggingface.co/x"] {
            #expect(!DownloadPolicy.isAllowed(URL(string: bad)!), "\(bad)")
        }
    }

    @Test func fileAddressesAreEscapedAndKeepTheirFolders() {
        let m = TestSupport.model(files: ["Encoder.mlmodelc/weights/weight.bin": Data([1]), "with space.txt": Data([1])])
        let urls = m.files.map { m.url(for: $0).absoluteString }
        #expect(urls.contains("https://huggingface.co/owner/name/resolve/\(m.revision)/Encoder.mlmodelc/weights/weight.bin"))
        #expect(urls.contains("https://huggingface.co/owner/name/resolve/\(m.revision)/with%20space.txt"))
    }
}

@Suite("The network code stays in one place")
struct ArchitectureTests {
    func swiftFiles(under folder: String) -> [URL] {
        let base = TestSupport.repoRoot.appendingPathComponent(folder)
        let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
        return (e?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    @Test func onlyTheDownloaderUsesTheNetwork() throws {
        var offenders: [String] = []
        for url in swiftFiles(under: "Sources") where !url.path.contains("/VoiceItDownloader/") {
            let text = try String(contentsOf: url, encoding: .utf8)
            for word in ["URLSession", "URLRequest", "NWConnection", "CFNetwork", "URLSessionWebSocketTask"] where text.contains(word) { offenders.append("\(url.lastPathComponent): \(word)") }
        }
        #expect(offenders.isEmpty, "network code outside the downloader: \(offenders)")
    }

    @Test func theCoreLibraryTheLogicAndTheHarnessNeverImportTheDownloader() throws {
        var offenders: [String] = []
        for folder in ["Sources/VoiceItCore", "Sources/VoiceItLogic", "Sources/VoiceItHarness"] {
            for url in swiftFiles(under: folder) where try String(contentsOf: url, encoding: .utf8).contains("VoiceItDownloader") { offenders.append(url.lastPathComponent) }
        }
        #expect(offenders.isEmpty, "\(offenders)")
        let package = try String(contentsOf: TestSupport.repoRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        for target in ["VoiceItCore", "VoiceItLogic", "VoiceItHarness"] {
            let start = try #require(package.range(of: "name: \"\(target)\""))
            let block = package[start.lowerBound...].prefix(while: { _ in true }).split(separator: "\n").prefix(8).joined(separator: "\n")
            #expect(!block.contains("VoiceItDownloader"), "\(target) must not depend on the downloader")
        }
    }

    @Test func theDownloaderItselfHasNoMachineLearningDependencies() throws {
        for url in swiftFiles(under: "Sources/VoiceItDownloader") {
            let text = try String(contentsOf: url, encoding: .utf8)
            for word in ["import MLX", "import FluidAudio", "import AVFoundation", "import AppKit"] { #expect(!text.contains(word), "\(url.lastPathComponent): \(word)") }
        }
    }
}
