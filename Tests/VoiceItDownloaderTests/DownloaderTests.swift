import Foundation
import Testing
@testable import VoiceItDownloader

/// A pretend server: every request the downloader makes is answered by `handler`, so no test touches the network.
final class StubProtocol: URLProtocol {
    enum Stub {
        /// Answer with `body`; if `thenFail` is set the connection then drops; if `hang` the answer never finishes.
        case respond(status: Int, headers: [String: String], body: Data, thenFail: URLError.Code?, hang: Bool)
        case redirect(URL, status: Int)
        case fail(URLError.Code)
    }
    nonisolated(unsafe) static var handler: ((URLRequest) -> Stub)?
    nonisolated(unsafe) static var seen: [URLRequest] = []
    private static let lock = NSLock()

    static func reset(_ h: @escaping (URLRequest) -> Stub) { lock.lock(); handler = h; seen = []; lock.unlock() }
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return seen }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.lock(); Self.seen.append(request); let h = Self.handler; Self.lock.unlock()
        guard let url = request.url, let stub = h?(request) else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        switch stub {
        case .fail(let code): client?.urlProtocol(self, didFailWithError: URLError(code))
        case .redirect(let to, let status):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Location": to.absoluteString])!
            var next = URLRequest(url: to)
            for (k, v) in request.allHTTPHeaderFields ?? [:] { next.setValue(v, forHTTPHeaderField: k) }
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
        case .respond(let status, let headers, let body, let thenFail, let hang):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let chunk = max(1, body.count / 4)
            var i = 0
            while i < body.count { client?.urlProtocol(self, didLoad: body.subdata(in: i..<min(body.count, i + chunk))); i += chunk }
            if hang { return }
            // A real connection drops after the data before it has been delivered, so give the data a moment to get through.
            if let code = thenFail { DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [weak self] in guard let self else { return }; self.client?.urlProtocol(self, didFailWithError: URLError(code)) } }
            else { client?.urlProtocolDidFinishLoading(self) }
        }
    }
}

extension StubProtocol.Stub {
    /// Serve `data` like a file host: honours a Range header unless told not to, and can drop the connection after some bytes.
    static func file(_ data: Data, for request: URLRequest, ranges: Bool = true, dropAfter: Int? = nil) -> Self {
        var start = 0, status = 200
        var headers = ["Content-Type": "application/octet-stream"]
        if ranges, let r = request.value(forHTTPHeaderField: "Range"), r.hasPrefix("bytes="), let s = Int(r.dropFirst(6).dropLast()) {
            start = s; status = 206; headers["Content-Range"] = "bytes \(s)-\(data.count - 1)/\(data.count)"
        }
        var body = data.subdata(in: start..<data.count)
        headers["Content-Length"] = "\(body.count)"
        var fail: URLError.Code?
        if let d = dropAfter { body = body.prefix(d); fail = .networkConnectionLost }
        return .respond(status: status, headers: headers, body: body, thenFail: fail, hang: false)
    }
}

@Suite("Model downloader", .serialized)
struct DownloaderTests {
    let free: () -> UInt64 = { 50 << 30 }

    func downloader(root: URL, free: (() -> UInt64)? = nil) -> ModelDownloader {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubProtocol.self]
        return ModelDownloader(root: root, configuration: c, freeBytes: free ?? self.free)
    }

    /// Serves each file of `files` from its manifest address.
    func serve(_ model: ModelManifest.Model, _ files: [String: Data], ranges: Bool = true, dropAfter: Int? = nil) {
        StubProtocol.reset { request in
            let prefix = "/owner/name/resolve/\(model.revision)/"
            guard let path = request.url?.path, path.hasPrefix(prefix), let data = files[String(path.dropFirst(prefix.count))] else { return .respond(status: 404, headers: [:], body: Data(), thenFail: nil, hang: false) }
            return .file(data, for: request, ranges: ranges, dropAfter: dropAfter)
        }
    }

    func read(_ model: ModelManifest.Model, _ root: URL, _ path: String) -> Data? {
        try? Data(contentsOf: root.appendingPathComponent(model.destination).appendingPathComponent(path))
    }

    @Test func downloadsEveryFileChecksItAndLeavesNoPartialFiles() async throws {
        let files = ["a.bin": TestSupport.blob(300_000, seed: 1), "sub/b.json": TestSupport.blob(5_000, seed: 2)]
        let model = TestSupport.model(files: files), root = TestSupport.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        serve(model, files)
        try await downloader(root: root).install([model]) { _ in }
        for (p, d) in files { #expect(read(model, root, p) == d) }
        #expect(ModelInstall.isComplete(model, root: root))
        let leftovers = (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".part") }
        #expect(leftovers.isEmpty)
    }

    @Test func aDroppedConnectionResumesFromWhereItStopped() async throws {
        let data = TestSupport.blob(400_000, seed: 3)
        let model = TestSupport.model(files: ["big.bin": data]), root = TestSupport.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        serve(model, ["big.bin": data], dropAfter: 150_000)
        await #expect(throws: ModelDownloader.DownloadError.self) { try await downloader(root: root).install([model]) { _ in } }
        let part = root.appendingPathComponent(model.destination).appendingPathComponent("big.bin.part")
        #expect(ModelDownloader.size(of: part) == 150_000)                       // what arrived is kept
        #expect(read(model, root, "big.bin") == nil)                             // and nothing is passed off as finished
        serve(model, ["big.bin": data])                                          // the connection is back
        try await downloader(root: root).install([model]) { _ in }
        #expect(read(model, root, "big.bin") == data)
        let resume = try #require(StubProtocol.requests.first)
        #expect(resume.value(forHTTPHeaderField: "Range") == "bytes=150000-")    // it asked only for the rest
        #expect(StubProtocol.requests.count == 1)
    }

    @Test func aServerThatIgnoresRangesMakesItStartOver() async throws {
        let data = TestSupport.blob(200_000, seed: 4)
        let model = TestSupport.model(files: ["f.bin": data]), root = TestSupport.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        serve(model, ["f.bin": data], dropAfter: 70_000)
        await #expect(throws: ModelDownloader.DownloadError.self) { try await downloader(root: root).install([model]) { _ in } }
        serve(model, ["f.bin": data], ranges: false)
        try await downloader(root: root).install([model]) { _ in }
        #expect(read(model, root, "f.bin") == data)                              // not 70,000 bytes of the old part plus a whole new copy
    }

    @Test func aFlippedByteIsRejectedAndNothingIsLeftBehind() async throws {
        let data = TestSupport.blob(100_000, seed: 5)
        var corrupted = data; corrupted[50_000] ^= 0xFF
        let model = TestSupport.model(files: ["m.bin": data]), root = TestSupport.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        serve(model, ["m.bin": corrupted])
        do { try await downloader(root: root).install([model]) { _ in }; Issue.record("should have failed") }
        catch let e as ModelDownloader.DownloadError { #expect(e == .checksumMismatch(file: "cleanup/m.bin")) }
        #expect(read(model, root, "m.bin") == nil)
        #expect(ModelDownloader.size(of: root.appendingPathComponent(model.destination).appendingPathComponent("m.bin.part")) == 0)
    }

    @Test func aFileThatIsTheWrongSizeIsRejected() async throws {
        let data = TestSupport.blob(100_000, seed: 6)
        let model = TestSupport.model(files: ["m.bin": data]), root = TestSupport.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        serve(model, ["m.bin": data + Data([1, 2, 3])])
        await #expect(throws: ModelDownloader.DownloadError.wrongSize(file: "cleanup/m.bin")) { try await downloader(root: root).install([model]) { _ in } }
        #expect(read(model, root, "m.bin") == nil)
    }

    @Test func notEnoughDiskStopsBeforeAnythingIsRequested() async throws {
        let files = ["a.bin": TestSupport.blob(400_000, seed: 7)]
        let model = TestSupport.model(files: files), root = TestSupport.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        serve(model, files)
        do { try await downloader(root: root, free: { 100_000 }).install([model]) { _ in }; Issue.record("should have failed") }
        catch let e as ModelDownloader.DownloadError {
            guard case .notEnoughDisk(let need, let have) = e else { Issue.record("wrong error \(e)"); return }
            #expect(need > 400_000 && have == 100_000)
            #expect(e.description.contains("free"))
        }
        #expect(StubProtocol.requests.isEmpty)
    }

    @Test func theSpeechModelAlsoNeedsRoomForItsCompiledCopy() async throws {
        let files = ["a.bin": TestSupport.blob(1_000, seed: 8)]
        let speech = TestSupport.model(id: "speech", files: files), other = TestSupport.model(id: "cleanup", files: files)
        let root = TestSupport.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        serve(speech, files)
        // 1,000 bytes to fetch plus a margin of at least 500 MB: a Mac with 400 MB free cannot do either.
        await #expect(throws: ModelDownloader.DownloadError.self) { try await downloader(root: root, free: { 400_000_000 }).install([speech]) { _ in } }
        _ = other
    }

    @Test func filesAlreadyInPlaceAreKeptWhenTheirChecksumIsRight() async throws {
        let files = ["a.bin": TestSupport.blob(50_000, seed: 9), "b.bin": TestSupport.blob(60_000, seed: 10)]
        let model = TestSupport.model(files: files), root = TestSupport.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        serve(model, files)
        try await downloader(root: root).install([model]) { _ in }
        StubProtocol.reset { _ in .fail(.notConnectedToInternet) }
        try await downloader(root: root).install([model]) { _ in }               // nothing to fetch, so being offline doesn't matter
        #expect(StubProtocol.requests.isEmpty)
    }

    @Test func aFileOfTheRightSizeButWrongContentIsReplaced() async throws {
        let data = TestSupport.blob(50_000, seed: 11)
        let model = TestSupport.model(files: ["a.bin": data]), root = TestSupport.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent(model.destination)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 50_000).write(to: folder.appendingPathComponent("a.bin"))
        serve(model, ["a.bin": data])
        try await downloader(root: root).install([model]) { _ in }
        #expect(read(model, root, "a.bin") == data)
    }

    @Test func aMissingFileOnTheServerIsAClearError() async throws {
        let model = TestSupport.model(files: ["a.bin": TestSupport.blob(1_000, seed: 12)]), root = TestSupport.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        serve(model, [:])
        await #expect(throws: ModelDownloader.DownloadError.httpStatus(404, file: "cleanup/a.bin")) { try await downloader(root: root).install([model]) { _ in } }
    }

    @Test func aRedirectToTheContentHostIsFollowedAndKeepsItsRange() async throws {
        let data = TestSupport.blob(120_000, seed: 13)
        let model = TestSupport.model(files: ["a.bin": data]), root = TestSupport.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let cdn = URL(string: "https://us.aws.cdn.hf.co/repos/xyz/a.bin")!
        StubProtocol.reset { request in
            request.url?.host == "huggingface.co" ? .redirect(cdn, status: 302) : .file(data, for: request)
        }
        try await downloader(root: root).install([model]) { _ in }
        #expect(read(model, root, "a.bin") == data)
        #expect(StubProtocol.requests.map { $0.url?.host } == ["huggingface.co", "us.aws.cdn.hf.co"])
    }

    @Test func aRedirectToAnyOtherHostIsRefusedAndNothingIsWritten() async throws {
        let data = TestSupport.blob(50_000, seed: 14)
        let model = TestSupport.model(files: ["a.bin": data]), root = TestSupport.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        StubProtocol.reset { request in
            request.url?.host == "huggingface.co" ? .redirect(URL(string: "https://evil.example.com/a.bin")!, status: 302) : .file(data, for: request)
        }
        do { try await downloader(root: root).install([model]) { _ in }; Issue.record("should have failed") }
        catch let e as ModelDownloader.DownloadError { #expect(e == .badAddress("evil.example.com")) }
        #expect(read(model, root, "a.bin") == nil)
        #expect(!StubProtocol.requests.contains { $0.url?.host == "evil.example.com" })       // it never even asked
        // And a redirect to plain http is no better.
        StubProtocol.reset { request in request.url?.host == "huggingface.co" ? .redirect(URL(string: "http://us.aws.cdn.hf.co/a.bin")!, status: 307) : .file(data, for: request) }
        await #expect(throws: ModelDownloader.DownloadError.self) { try await downloader(root: root).install([model]) { _ in } }
    }

    @Test func aManifestPointingAnywhereElseIsRefusedBeforeAnyRequest() async throws {
        let root = TestSupport.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let escape = ModelManifest.Model(id: "m", name: "n", repo: "o/r", revision: String(repeating: "a", count: 40), licence: "MIT", destination: "d",
                                         files: [.init(path: "../../outside", sha256: String(repeating: "0", count: 64), size: 1)])
        StubProtocol.reset { _ in .fail(.cannotFindHost) }
        await #expect(throws: ModelDownloader.DownloadError.self) { try await downloader(root: root).install([escape]) { _ in } }
        #expect(StubProtocol.requests.isEmpty)
    }

    @Test func requestsCarryNothingButAGenericUserAgent() async throws {
        let data = TestSupport.blob(20_000, seed: 15)
        let model = TestSupport.model(files: ["a.bin": data]), root = TestSupport.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        serve(model, ["a.bin": data])
        try await downloader(root: root).install([model]) { _ in }
        let request = try #require(StubProtocol.requests.first)
        let headers = request.allHTTPHeaderFields ?? [:]
        #expect(headers["User-Agent"] == ModelDownloader.userAgent)
        #expect(headers["Accept-Encoding"] == "identity")                         // the bytes on the wire are the bytes the checksum covers
        for forbidden in ["Cookie", "Authorization", "Referer", "Origin", "X-Forwarded-For"] { #expect(headers[forbidden] == nil, "\(forbidden)") }
        #expect(request.httpMethod == "GET" && request.httpBody == nil)
        #expect(request.url?.query == nil)                                         // no identifiers in the address either
        #expect(!ModelDownloader.userAgent.contains(NSUserName()) && !ModelDownloader.userAgent.contains(ProcessInfo.processInfo.hostName))
    }

    @Test func progressNeverGoesBackwardsAndEndsAtTheTotal() async throws {
        let files = ["a.bin": TestSupport.blob(300_000, seed: 16), "b.bin": TestSupport.blob(200_000, seed: 17)]
        let model = TestSupport.model(files: files), root = TestSupport.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        serve(model, files)
        final class Seen: @unchecked Sendable { var values: [ModelDownloader.Progress] = []; let lock = NSLock() }
        let seen = Seen()
        try await downloader(root: root).install([model]) { seen.lock.lock(); seen.values.append($0); seen.lock.unlock() }
        let done = seen.values.map(\.bytesDone)
        #expect(done == done.sorted())
        #expect(seen.values.last?.bytesDone == 500_000 && seen.values.last?.bytesTotal == 500_000 && seen.values.last?.fraction == 1)
    }

    @Test func cancellingKeepsWhatArrivedSoTheNextTryResumes() async throws {
        let data = TestSupport.blob(200_000, seed: 18)
        let model = TestSupport.model(files: ["a.bin": data]), root = TestSupport.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        StubProtocol.reset { request in .respond(status: 200, headers: ["Content-Length": "\(data.count)"], body: data.prefix(80_000), thenFail: nil, hang: true) }
        let d = downloader(root: root)
        let task = Task { try await d.install([model]) { _ in } }
        let part = root.appendingPathComponent(model.destination).appendingPathComponent("a.bin.part")
        for _ in 0..<100 where ModelDownloader.size(of: part) < 80_000 { try await Task.sleep(nanoseconds: 20_000_000) }
        task.cancel()
        do { try await task.value; Issue.record("should have been cancelled") } catch let e as ModelDownloader.DownloadError { #expect(e == .cancelled) }
        #expect(ModelDownloader.size(of: part) == 80_000)
    }

    @Test func eachFailureHasWordsAUserCanActOn() {
        let all: [ModelDownloader.DownloadError] = [.notEnoughDisk(needed: 3_000_000_000, available: 1_000_000_000), .badAddress("x.com"), .httpStatus(503, file: "f"),
                                                    .checksumMismatch(file: "f"), .wrongSize(file: "f"), .interrupted(file: "f", reason: "offline"), .disk("full"), .cancelled]
        for e in all { #expect(e.description.count > 20 && !e.description.contains("DownloadError")) }
        #expect(all[0].description.contains("3.0 GB") && all[0].description.contains("1.0 GB"))
    }
}
