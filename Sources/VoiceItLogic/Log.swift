import Foundation

/// An append-only text file that keeps itself small: when it passes `limit` bytes it becomes `<name>.1` (replacing the previous
/// one) and a fresh file starts, so the log never takes more than about twice `limit`. Not thread-safe; `Log` calls it from one queue.
public final class RotatingLogFile {
    public let url: URL
    private let limit: Int
    private var size: Int?

    public init(url: URL, limit: Int = 1_000_000) { self.url = url; self.limit = limit }

    public var previousURL: URL { url.appendingPathExtension("1") }

    public func append(_ line: String) {
        let data = Data(line.utf8)
        let current = size ?? ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        if current + data.count > limit && current > 0 { rotate() ; size = 0 } else { size = current }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
        size = (size ?? 0) + data.count
    }

    private func rotate() {
        try? FileManager.default.removeItem(at: previousURL)
        try? FileManager.default.moveItem(at: url, to: previousURL)
    }
}

/// Plain log at ~/Library/Logs/Voice It/voice-it.log (rotated at 1 MB), also echoed to stderr.
/// Nothing is written to the file while the unit tests run, so a test run never leaves lines in the owner's real log.
public enum Log {
    public static let url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/\(AppIdentity.name)").appendingPathComponent(AppIdentity.logFileName)
    private static let queue = DispatchQueue(label: "voice-it.log")
    private static let file = RotatingLogFile(url: url)
    private static let writesToFile: Bool = {
        let env = ProcessInfo.processInfo.environment, name = ProcessInfo.processInfo.arguments.first ?? ""
        return env["XCTestConfigurationFilePath"] == nil && env["SWIFT_TESTING_ENABLED"] == nil
            && !name.contains("xctest") && !name.contains("swiftpm-testing-helper")
    }()
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func info(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        guard writesToFile else { return }
        queue.async { file.append(line) }
    }
}
