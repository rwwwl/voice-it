import CryptoKit
import Foundation
import VoiceItLogic

/// Downloads the models in a manifest into the models folder, checking every file against its SHA-256.
///
/// This is the only network code in the project. It talks only to Hugging Face over https (and the content hosts it redirects to, see
/// `DownloadPolicy`), sends a fixed generic user agent and nothing that identifies the user or the Mac (no cookies, no cache, no account),
/// resumes an interrupted download where it stopped, and moves a file into place only once its size and checksum are right.
public final class ModelDownloader {
    public struct Progress: Equatable, Sendable {
        public var bytesDone: Int64
        public var bytesTotal: Int64
        /// The file being fetched or checked, "folder/name".
        public var file: String
        public init(bytesDone: Int64, bytesTotal: Int64, file: String) { self.bytesDone = bytesDone; self.bytesTotal = bytesTotal; self.file = file }
        public var fraction: Double { bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : 0 }
    }

    public enum DownloadError: Error, Equatable, CustomStringConvertible {
        case notEnoughDisk(needed: Int64, available: Int64)
        case badAddress(String)
        case httpStatus(Int, file: String)
        case checksumMismatch(file: String)
        case wrongSize(file: String)
        /// The connection dropped or ended early. Nothing is lost: the next attempt carries on from where this one stopped.
        case interrupted(file: String, reason: String)
        case disk(String)
        case cancelled

        public var description: String {
            switch self {
            case .notEnoughDisk(let need, let have):
                return "There isn't enough free disk space. About \(Self.size(need)) is needed and \(Self.size(have)) is free. Free up some space and try again."
            case .badAddress(let a): return "The download was refused because \(a) is not an address Voice It is allowed to use."
            case .httpStatus(let code, let file): return "The server answered \(code) for \(file). Try again in a little while."
            case .checksumMismatch(let file): return "\(file) did not match its checksum, so it was thrown away. Try again; if it keeps happening, the file on the server may have changed."
            case .wrongSize(let file): return "\(file) came back at the wrong size, so it was thrown away. Try again."
            case .interrupted(let file, let why): return "The download stopped while fetching \(file) (\(why)). Check the connection and try again: it will carry on where it stopped."
            case .disk(let why): return "The files could not be written (\(why))."
            case .cancelled: return "The download was cancelled. Anything already fetched is kept, and the next try carries on from it."
            }
        }

        static func size(_ bytes: Int64) -> String { bytes >= 1_000_000_000 ? String(format: "%.1f GB", Double(bytes) / 1e9) : String(format: "%.0f MB", Double(bytes) / 1e6) }
    }

    public static let userAgent = "VoiceIt-ModelDownloader"

    public let root: URL
    private let configuration: URLSessionConfiguration
    private let freeBytes: () -> Int64

    /// `root` is the models folder. `configuration` and `freeBytes` are for tests.
    public init(root: URL, configuration: URLSessionConfiguration? = nil, freeBytes: (() -> UInt64)? = nil) {
        self.root = root
        self.configuration = Self.hardened(configuration ?? .ephemeral)
        self.freeBytes = freeBytes.map { f in { Int64(clamping: f()) } } ?? { Int64(clamping: Requirements.freeDiskBytes(at: root)) }
    }

    /// Nothing that could identify the user: no cookies, no cache, no account, and one fixed user agent and language.
    static func hardened(_ base: URLSessionConfiguration) -> URLSessionConfiguration {
        let c = base
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.urlCredentialStorage = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpMaximumConnectionsPerHost = 1
        c.waitsForConnectivity = false
        c.timeoutIntervalForRequest = 60            // gives up if nothing arrives for a minute; the next try resumes
        c.httpAdditionalHeaders = ["User-Agent": userAgent, "Accept-Language": "en", "Accept-Encoding": "identity", "Accept": "*/*"]
        return c
    }

    // MARK: Installing

    /// Fetches whatever is missing or wrong for these models. Safe to call again after a failure: finished files are kept and partial ones resume.
    public func install(_ models: [ModelManifest.Model], progress: @escaping (Progress) -> Void) async throws {
        for m in models {
            for f in m.files {
                guard ModelManifest.isSafeRelativePath(f.path), ModelManifest.isSafeRelativePath(m.destination) else { throw DownloadError.badAddress("the path \"\(f.path)\"") }
                guard DownloadPolicy.isAllowed(m.url(for: f)) else { throw DownloadError.badAddress(m.url(for: f).host ?? "that address") }
            }
        }
        let total = models.reduce(Int64(0)) { $0 + $1.totalBytes }
        let reporter = Reporter(total: total, callback: progress)

        // 1. Files already in place are kept if their checksum is right, and thrown away if not.
        var pending: [(ModelManifest.Model, ModelManifest.File)] = []
        for m in models {
            for f in m.files {
                let final = Self.location(of: f, in: m, root: root)
                if Self.size(of: final) == f.size {
                    reporter.set(file: Self.label(f, m))
                    if (try? Self.sha256(of: final, onBytes: { reporter.add($0) })) == f.sha256 { continue }
                    reporter.add(-f.size)
                    try? FileManager.default.removeItem(at: final)
                } else if Self.size(of: final) > 0 { try? FileManager.default.removeItem(at: final) }
                pending.append((m, f))
            }
        }

        // 2. Is there room for what is left? The speech model is also compiled on its first load, which takes about as much space again.
        let partial = pending.reduce(Int64(0)) { $0 + min($1.1.size, Self.size(of: Self.partLocation(of: $1.1, in: $1.0, root: root))) }
        let remaining = pending.reduce(Int64(0)) { $0 + $1.1.size } - partial
        if remaining > 0 {
            let compiled = pending.contains { $0.0.id == "speech" } ? (models.first { $0.id == "speech" }?.totalBytes ?? 0) : 0
            let needed = Self.spaceNeeded(remaining: remaining, compiledCopy: compiled)
            let have = freeBytes()
            guard have >= needed else { throw DownloadError.notEnoughDisk(needed: needed, available: have) }
        }
        for (m, f) in pending { reporter.add(min(f.size, Self.size(of: Self.partLocation(of: f, in: m, root: root)))) }

        // 3. Fetch the rest, one file at a time.
        for (m, f) in pending {
            reporter.set(file: Self.label(f, m))
            do { try await download(f, of: m, reporter: reporter) }
            catch is CancellationError { throw DownloadError.cancelled }
        }
        reporter.finish()
    }

    // MARK: One file

    private func download(_ file: ModelManifest.File, of model: ModelManifest.Model, reporter: Reporter) async throws {
        let fm = FileManager.default
        let final = Self.location(of: file, in: model, root: root), part = Self.partLocation(of: file, in: model, root: root)
        do { try fm.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true) }
        catch { throw DownloadError.disk(error.localizedDescription) }

        var offset = Self.size(of: part)
        if offset > file.size { try? fm.removeItem(at: part); reporter.add(-offset); offset = 0 }
        if offset == 0 { guard fm.createFile(atPath: part.path, contents: nil) else { throw DownloadError.disk("can't create \(part.lastPathComponent)") } }

        var hasher = SHA256()
        if offset > 0 { try Self.feed(&hasher, from: part) }
        var received = offset

        if received < file.size {
            let transfer = Transfer(file: Self.label(file, model), part: part, offset: offset, hasher: hasher, reporter: reporter)
            let session = URLSession(configuration: configuration, delegate: transfer, delegateQueue: { let q = OperationQueue(); q.maxConcurrentOperationCount = 1; return q }())
            defer { session.finishTasksAndInvalidate() }
            var request = URLRequest(url: model.url(for: file))
            if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
            let task = session.dataTask(with: request)
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in transfer.begin(task, c) }
            } onCancel: { transfer.cancel() }
            hasher = transfer.hasher
            received = transfer.received
        }

        if received < file.size { throw DownloadError.interrupted(file: Self.label(file, model), reason: "the connection ended early") }
        if received > file.size { try? fm.removeItem(at: part); reporter.add(-received); throw DownloadError.wrongSize(file: Self.label(file, model)) }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == file.sha256 else {
            try? fm.removeItem(at: part); reporter.add(-received)
            throw DownloadError.checksumMismatch(file: Self.label(file, model))
        }
        do { try? fm.removeItem(at: final); try fm.moveItem(at: part, to: final) }
        catch { throw DownloadError.disk(error.localizedDescription) }
    }

    // MARK: Helpers

    /// Free space needed to fetch `remaining` bytes: the bytes themselves, the compiled copy macOS makes of the speech model on its first
    /// load (about as big as the model), and a margin of at least 500 MB or 10%. The setup window shows the same figure.
    public static func spaceNeeded(remaining: Int64, compiledCopy: Int64) -> Int64 { remaining + compiledCopy + max(500_000_000, remaining / 10) }

    static func location(of file: ModelManifest.File, in model: ModelManifest.Model, root: URL) -> URL {
        root.appendingPathComponent(model.destination, isDirectory: true).appendingPathComponent(file.path)
    }
    static func partLocation(of file: ModelManifest.File, in model: ModelManifest.Model, root: URL) -> URL {
        location(of: file, in: model, root: root).appendingPathExtension("part")
    }
    static func label(_ file: ModelManifest.File, _ model: ModelManifest.Model) -> String { "\(model.id)/\(file.path)" }
    static func size(of url: URL) -> Int64 { ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0 }

    static func feed(_ hasher: inout SHA256, from url: URL, onBytes: ((Int64) -> Void)? = nil) throws {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk); onBytes?(Int64(chunk.count)) }
    }

    /// The SHA-256 of a file, as 64 lowercase hex characters.
    public static func sha256(of url: URL, onBytes: ((Int64) -> Void)? = nil) throws -> String {
        var h = SHA256(); try feed(&h, from: url, onBytes: onBytes)
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Whether a model's files are all on disk at the right sizes. Quick (no hashing), so the app can ask it at every launch.
public enum ModelInstall {
    public static func isComplete(_ model: ModelManifest.Model, root: URL) -> Bool {
        model.files.allSatisfy { ModelDownloader.size(of: ModelDownloader.location(of: $0, in: model, root: root)) == $0.size }
    }
}

/// Adds up bytes from the transfer and the checks and reports them, at most ten times a second.
private final class Reporter: @unchecked Sendable {
    private let lock = NSLock()
    private let total: Int64
    private let callback: (ModelDownloader.Progress) -> Void
    private var done: Int64 = 0
    private var file = ""
    private var lastReport = Date.distantPast

    init(total: Int64, callback: @escaping (ModelDownloader.Progress) -> Void) { self.total = total; self.callback = callback }

    func set(file: String) { lock.lock(); self.file = file; lock.unlock() }
    func add(_ bytes: Int64) {
        lock.lock(); done = max(0, min(total, done + bytes))
        let now = Date(), due = now.timeIntervalSince(lastReport) >= 0.1
        if due { lastReport = now }
        let snapshot = ModelDownloader.Progress(bytesDone: done, bytesTotal: total, file: file)
        lock.unlock()
        if due { callback(snapshot) }
    }
    func finish() { lock.lock(); let s = ModelDownloader.Progress(bytesDone: done, bytesTotal: total, file: file); lock.unlock(); callback(s) }
}

/// One file's transfer. Runs on the session's serial queue; the hasher and byte count are read only after it has finished.
private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let file: String
    let part: URL
    let reporter: Reporter
    private(set) var hasher: SHA256
    private(set) var received: Int64
    private var handle: FileHandle?
    private var failure: ModelDownloader.DownloadError?
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDataTask?
    private var cancelledByCaller = false
    private let lock = NSLock()

    init(file: String, part: URL, offset: Int64, hasher: SHA256, reporter: Reporter) {
        self.file = file; self.part = part; self.received = offset; self.hasher = hasher; self.reporter = reporter
    }

    func begin(_ task: URLSessionDataTask, _ c: CheckedContinuation<Void, Error>) {
        lock.lock(); self.task = task; continuation = c; let already = cancelledByCaller; lock.unlock()
        if already { task.cancel() }
        task.resume()
    }
    func cancel() { lock.lock(); cancelledByCaller = true; let t = task; lock.unlock(); t?.cancel() }

    private func fail(_ e: ModelDownloader.DownloadError) { if failure == nil { failure = e } }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, DownloadPolicy.isAllowed(url) else {
            fail(.badAddress(request.url?.host ?? "that address")); completionHandler(nil); task.cancel(); return
        }
        var next = request
        if let range = task.originalRequest?.value(forHTTPHeaderField: "Range") { next.setValue(range, forHTTPHeaderField: "Range") }
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { fail(.httpStatus(0, file: file)); completionHandler(.cancel); return }
        let resuming = received > 0
        switch (resuming, http.statusCode) {
        case (_, 200):
            if resuming { received = 0; hasher = SHA256(); reporter.add(-Self.size(of: part)) }    // the server ignored the range: start over
        case (true, 206):
            // Content-Range: bytes START-END/TOTAL. START must be where we stopped.
            let start = http.value(forHTTPHeaderField: "Content-Range").flatMap { $0.split(separator: " ").last?.split(separator: "-").first }.flatMap { Int64($0) }
            if start != received { fail(.interrupted(file: file, reason: "the server resumed at the wrong place")); completionHandler(.cancel); return }
        default:
            fail(.httpStatus(http.statusCode, file: file)); completionHandler(.cancel); return
        }
        do {
            let h = try FileHandle(forWritingTo: part)
            if received == 0 { try h.truncate(atOffset: 0) } else { try h.seekToEnd() }
            handle = h
        } catch { fail(.disk(error.localizedDescription)); completionHandler(.cancel); return }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let handle, failure == nil else { return }
        do { try handle.write(contentsOf: data) } catch { fail(.disk(error.localizedDescription)); dataTask.cancel(); return }
        hasher.update(data: data)
        received += Int64(data.count)
        reporter.add(Int64(data.count))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close(); handle = nil
        lock.lock(); let c = continuation; continuation = nil; let byCaller = cancelledByCaller; lock.unlock()
        if let failure { c?.resume(throwing: failure) }
        else if byCaller { c?.resume(throwing: CancellationError()) }
        else if let error { c?.resume(throwing: ModelDownloader.DownloadError.interrupted(file: file, reason: (error as NSError).localizedDescription)) }
        else { c?.resume() }
    }

    private static func size(of url: URL) -> Int64 { ModelDownloader.size(of: url) }
}
