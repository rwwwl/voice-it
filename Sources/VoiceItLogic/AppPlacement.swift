import Foundation

/// Where the running app sits, and copying it to Applications. Permissions are tied to an app's identity and location, so an app that is run
/// from Downloads (or from the temporary read-only copy macOS makes of a downloaded app, "app translocation") is best moved first.
public enum AppLocation: Equatable, Sendable {
    case applications, userApplications, translocated, other
}

public enum AppPlacement {
    /// Apple offers no supported way to ask whether an app was translocated; its path always contains `AppTranslocation`.
    public static func classify(bundlePath: String, home: String) -> AppLocation {
        if bundlePath.contains("/AppTranslocation/") { return .translocated }
        if bundlePath.hasPrefix("/Applications/") { return .applications }
        let userApps = home.hasSuffix("/") ? home + "Applications/" : home + "/Applications/"
        if bundlePath.hasPrefix(userApps) { return .userApplications }
        return .other
    }

    public static func needsMove(_ location: AppLocation) -> Bool { location == .translocated || location == .other }

    /// Where a copy may go, in order of preference: /Applications, then ~/Applications (for a standard account that can't write the first).
    /// `VOICEIT_APPLICATIONS_DIR` replaces both, so the move can be tried without touching the real folders (a developer aid).
    public static func destinationFolders(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        if let override = ProcessInfo.processInfo.environment["VOICEIT_APPLICATIONS_DIR"] { return [URL(fileURLWithPath: override, isDirectory: true)] }
        return [URL(fileURLWithPath: "/Applications", isDirectory: true), home.appendingPathComponent("Applications", isDirectory: true)]
    }

    /// A short, readable place name for the window: "Downloads", "the Desktop", or the folder's own name.
    public static func friendlyPlace(of bundlePath: String, home: String) -> String {
        let folder = (bundlePath as NSString).deletingLastPathComponent
        if bundlePath.contains("/AppTranslocation/") { return "a temporary location macOS made for it" }
        if folder == home + "/Downloads" { return "your Downloads folder" }
        if folder == home + "/Desktop" { return "your Desktop" }
        if folder == home { return "your home folder" }
        return "“\((folder as NSString).lastPathComponent)”"
    }
}

/// Copies an app bundle into the first folder that accepts it. Never renames or moves the original, and never touches the copy's extended
/// attributes: the quarantine mark macOS put on a download stays exactly as it was.
public enum AppCopier {
    public struct Result: Equatable, Sendable {
        public let url: URL
        /// True when the first folder refused and a later one was used.
        public let usedFallback: Bool
    }

    public enum CopyError: Error, Equatable, CustomStringConvertible {
        case nowhereToCopy([String])
        public var description: String {
            switch self {
            case .nowhereToCopy(let why): return "Voice It couldn't be copied to Applications (\(why.joined(separator: "; "))). You can drag it there yourself in Finder."
            }
        }
    }

    public static func install(app: URL, into folders: [URL]) throws -> Result {
        let fm = FileManager.default
        var problems: [String] = []
        for (index, folder) in folders.enumerated() {
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let destination = folder.appendingPathComponent(app.lastPathComponent, isDirectory: true)
                // Copy beside the destination first, then swap it in: a failed copy never damages an app that is already there.
                let staging = folder.appendingPathComponent(".\(app.lastPathComponent).copying-\(UUID().uuidString)", isDirectory: true)
                do {
                    try fm.copyItem(at: app, to: staging)
                    if fm.fileExists(atPath: destination.path) { _ = try fm.replaceItemAt(destination, withItemAt: staging) }
                    else { try fm.moveItem(at: staging, to: destination) }
                } catch { try? fm.removeItem(at: staging); throw error }
                return Result(url: destination, usedFallback: index > 0)
            } catch {
                problems.append("\(folder.path): \((error as NSError).localizedDescription)")
            }
        }
        throw CopyError.nowhereToCopy(problems)
    }
}
