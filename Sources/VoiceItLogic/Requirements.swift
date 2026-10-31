import Foundation

/// Which models a setup needs: only the speech model (enough for the Exact style), or the cleanup model as well.
public enum ModelSet: String, Codable, CaseIterable, Sendable {
    case speechOnly
    case withCleanup

    public var needsCleanupModel: Bool { self == .withCleanup }
}

/// Sizes of the pinned model files in bytes, until the downloader's manifest (step 8.3) supplies them.
public enum ModelSizes {
    public static let speech: UInt64 = 464_413_250
    public static let cleanup: UInt64 = 2_278_972_236
    public static func download(for models: ModelSet) -> UInt64 { models.needsCleanupModel ? speech + cleanup : speech }
}

public struct OSVersion: Equatable, Comparable, Sendable, CustomStringConvertible {
    public var major: Int, minor: Int, patch: Int
    public init(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) { self.major = major; self.minor = minor; self.patch = patch }
    public static func < (a: OSVersion, b: OSVersion) -> Bool { (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch) }
    public var description: String { patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)" }
}

/// What the Mac is, as measured. Injectable so every case can be tested.
public struct SystemFacts: Equatable, Sendable {
    public var isAppleSilicon: Bool
    public var macOS: OSVersion
    public var memoryBytes: UInt64
    public var freeDiskBytes: UInt64
    public init(isAppleSilicon: Bool, macOS: OSVersion, memoryBytes: UInt64, freeDiskBytes: UInt64) {
        self.isAppleSilicon = isAppleSilicon; self.macOS = macOS; self.memoryBytes = memoryBytes; self.freeDiskBytes = freeDiskBytes
    }
}

public struct RequirementResult: Equatable, Sendable {
    public enum Item: String, Sendable { case appleSilicon, macOS, memory, disk }
    public enum Status: String, Sendable { case ok, warning, failed }
    public let item: Item
    public let status: Status
    /// One plain sentence or two, saying exactly what is wrong and what to do.
    public let message: String
    /// A few words, for the small overlay pill.
    public let short: String
}

public struct RequirementsReport: Equatable, Sendable {
    public let results: [RequirementResult]
    public var failures: [RequirementResult] { results.filter { $0.status == .failed } }
    public var warnings: [RequirementResult] { results.filter { $0.status == .warning } }
    /// False if anything failed: the app should say what, and stop.
    public var canContinue: Bool { failures.isEmpty }
    /// The cleanup model as well on Macs with 16 GB or more; otherwise the speech model alone (Exact style).
    public let recommendedModels: ModelSet
}

public enum Requirements {
    public static let minimumMacOS = OSVersion(15, 0)
    /// Below this the speech model alone is too much for the Mac.
    public static let minimumMemoryBytes: UInt64 = 8 << 30
    /// The cleanup model is tested and recommended from here up (measured: about 2.4 GB resident and 4.6 GB peak, on a 32 GB Mac only).
    public static let fullCleanupMemoryBytes: UInt64 = 16 << 30

    /// Free space needed: the download, plus the compiled copy Core ML makes of the speech model on first load (measured: about the
    /// same size as the model), plus a margin of 500 MB or 10%, whichever is larger.
    public static func requiredFreeBytes(for models: ModelSet) -> UInt64 {
        let base = ModelSizes.download(for: models) + ModelSizes.speech
        return base + max(500_000_000, base / 10)
    }

    /// `checkDisk: false` is for launches after the models are already in place, where free space no longer matters.
    public static func check(facts: SystemFacts, models: ModelSet, checkDisk: Bool = true) -> RequirementsReport {
        var results: [RequirementResult] = []

        results.append(facts.isAppleSilicon
            ? RequirementResult(item: .appleSilicon, status: .ok, message: "Apple silicon.", short: "Apple silicon")
            : RequirementResult(item: .appleSilicon, status: .failed,
                                message: "Voice It needs a Mac with Apple silicon (M1 or later). This Mac has an Intel processor.",
                                short: "Needs Apple silicon"))

        results.append(facts.macOS >= minimumMacOS
            ? RequirementResult(item: .macOS, status: .ok, message: "macOS \(facts.macOS).", short: "macOS \(facts.macOS)")
            : RequirementResult(item: .macOS, status: .failed,
                                message: "Voice It needs macOS \(minimumMacOS.major) (Sequoia) or later. This Mac has macOS \(facts.macOS).",
                                short: "Needs macOS \(minimumMacOS.major) or later"))

        let memory = gigabytes(facts.memoryBytes)
        if facts.memoryBytes < minimumMemoryBytes {
            results.append(RequirementResult(item: .memory, status: .failed,
                message: "Voice It needs at least \(gigabytes(minimumMemoryBytes)) of memory. This Mac has \(memory).",
                short: "Needs \(gigabytes(minimumMemoryBytes)) of memory"))
        } else if models == .withCleanup && facts.memoryBytes < fullCleanupMemoryBytes {
            results.append(RequirementResult(item: .memory, status: .warning,
                message: "This Mac has \(memory) of memory. The cleanup model is tested and recommended on Macs with \(gigabytes(fullCleanupMemoryBytes)) or more, so the Exact style is recommended here. It still applies your dictionary, snippets and spoken formatting, but doesn't use the cleanup model.",
                short: "\(memory): Exact style recommended"))
        } else {
            results.append(RequirementResult(item: .memory, status: .ok, message: "\(memory) of memory.", short: "\(memory) of memory"))
        }

        if checkDisk {
            let need = requiredFreeBytes(for: models), have = facts.freeDiskBytes
            results.append(have >= need
                ? RequirementResult(item: .disk, status: .ok, message: "\(size(have)) free (\(size(need)) needed).", short: "\(size(have)) free")
                : RequirementResult(item: .disk, status: .failed,
                                    message: "There isn't enough free disk space. Voice It needs about \(size(need)) free to download and prepare the models (the download itself is \(size(ModelSizes.download(for: models)))), and this Mac has \(size(have)) free. Free up some space and try again.",
                                    short: "Not enough free disk space"))
        }

        return RequirementsReport(results: results, recommendedModels: facts.memoryBytes >= fullCleanupMemoryBytes ? .withCleanup : .speechOnly)
    }

    // MARK: Reading the real Mac

    /// `path` is where the models will go; its volume is the one checked for free space.
    public static func currentFacts(at path: URL) -> SystemFacts {
        var arm64: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let armOK = sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0) == 0 && arm64 == 1
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return SystemFacts(isAppleSilicon: armOK, macOS: OSVersion(v.majorVersion, v.minorVersion, v.patchVersion),
                           memoryBytes: ProcessInfo.processInfo.physicalMemory, freeDiskBytes: freeDiskBytes(at: path))
    }

    /// Free space on the volume holding `path`, counting space macOS can reclaim. Looks at the nearest folder that exists.
    public static func freeDiskBytes(at path: URL) -> UInt64 {
        var url = path
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 { url.deleteLastPathComponent() }
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return UInt64(important) }
        return UInt64(max(0, values?.volumeAvailableCapacity ?? 0))
    }

    // MARK: Wording

    private static func gigabytes(_ bytes: UInt64) -> String { "\(Int((Double(bytes) / Double(1 << 30)).rounded())) GB" }

    /// Disk sizes the way Finder shows them (decimal), to one decimal place: "2.7 GB", "464 MB".
    private static func size(_ bytes: UInt64) -> String {
        bytes >= 1_000_000_000 ? String(format: "%.1f GB", Double(bytes) / 1e9) : String(format: "%.0f MB", Double(bytes) / 1e6)
    }
}
