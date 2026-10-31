import Darwin
import Foundation
import Testing
@testable import VoiceItLogic

@Suite("Where the app is, and copying it")
struct AppPlacementTests {
    let home = "/Users/someone"

    @Test func theLocationIsRecognised() {
        func c(_ p: String) -> AppLocation { AppPlacement.classify(bundlePath: p, home: home) }
        #expect(c("/Applications/Voice It.app") == .applications)
        #expect(c("/Applications/Utilities/Voice It.app") == .applications)
        #expect(c("/Users/someone/Applications/Voice It.app") == .userApplications)
        #expect(c("/Users/someone/Downloads/Voice It.app") == .other)
        #expect(c("/Users/someone/Developer/dictate/build/Voice It.app") == .other)
        #expect(c("/Volumes/Voice It/Voice It.app") == .other)                                   // run straight from the disk image
        #expect(c("/private/var/folders/ab/cd/T/AppTranslocation/1234-ABCD/d/Voice It.app") == .translocated)
        #expect(c("/Users/someone/ApplicationsOld/Voice It.app") == .other)                     // only the real Applications folder counts
        #expect(AppPlacement.classify(bundlePath: "/Users/someone/Applications/x.app", home: "/Users/someone/") == .userApplications)
    }

    @Test func onlyAnAppOutsideApplicationsNeedsMoving() {
        #expect(AppPlacement.needsMove(.other) && AppPlacement.needsMove(.translocated))
        #expect(!AppPlacement.needsMove(.applications) && !AppPlacement.needsMove(.userApplications))
    }

    @Test func theFoldersAreTriedInOrder() {
        let folders = AppPlacement.destinationFolders(home: URL(fileURLWithPath: home))
        #expect(folders.map(\.path) == ["/Applications", "/Users/someone/Applications"])
    }

    @Test func theWindowNamesWhereTheAppIsInPlainWords() {
        #expect(AppPlacement.friendlyPlace(of: "/Users/someone/Downloads/Voice It.app", home: home) == "your Downloads folder")
        #expect(AppPlacement.friendlyPlace(of: "/Users/someone/Desktop/Voice It.app", home: home) == "your Desktop")
        #expect(AppPlacement.friendlyPlace(of: "/Users/someone/Voice It.app", home: home) == "your home folder")
        #expect(AppPlacement.friendlyPlace(of: "/Users/someone/Stuff/Voice It.app", home: home) == "“Stuff”")
        #expect(AppPlacement.friendlyPlace(of: "/private/var/folders/x/AppTranslocation/1/d/Voice It.app", home: home).contains("temporary"))
    }
}

@Suite("Copying the app")
struct AppCopierTests {
    func scratch() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("voice-it-copy-\(UUID().uuidString)", isDirectory: true) }

    /// A small pretend app bundle: an executable, a nested resource, and a quarantine mark like a download carries.
    func makeApp(in dir: URL, marker: String = "v1") throws -> URL {
        let app = dir.appendingPathComponent("Voice It.app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try "binary \(marker)".write(to: macOS.appendingPathComponent("VoiceIt"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: macOS.appendingPathComponent("VoiceIt").path)
        try "plist".write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        let quarantine = "0083;5f5e1000;Safari;"
        #expect(setxattr(app.path, "com.apple.quarantine", quarantine, quarantine.utf8.count, 0, 0) == 0)
        return app
    }

    func xattr(_ url: URL, _ name: String) -> String? {
        let n = getxattr(url.path, name, nil, 0, 0, 0)
        guard n > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: n)
        guard getxattr(url.path, name, &buffer, n, 0, 0) == n else { return nil }
        return String(decoding: buffer, as: UTF8.self)
    }

    @Test func theWholeBundleIsCopiedAndTheOriginalIsLeftAlone() throws {
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeApp(in: root.appendingPathComponent("Downloads"))
        let result = try AppCopier.install(app: app, into: [root.appendingPathComponent("Applications")])
        #expect(result.url.lastPathComponent == "Voice It.app" && !result.usedFallback)
        #expect(try String(contentsOf: result.url.appendingPathComponent("Contents/MacOS/VoiceIt"), encoding: .utf8) == "binary v1")
        #expect(FileManager.default.isExecutableFile(atPath: result.url.appendingPathComponent("Contents/MacOS/VoiceIt").path))
        #expect(FileManager.default.fileExists(atPath: app.path))                                        // copied, not moved
        #expect(try String(contentsOf: app.appendingPathComponent("Contents/MacOS/VoiceIt"), encoding: .utf8) == "binary v1")
    }

    @Test func theQuarantineMarkIsNeitherAddedNorRemoved() throws {
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeApp(in: root.appendingPathComponent("Downloads"))
        let result = try AppCopier.install(app: app, into: [root.appendingPathComponent("Applications")])
        #expect(xattr(result.url, "com.apple.quarantine") == xattr(app, "com.apple.quarantine"))
        #expect(xattr(app, "com.apple.quarantine") == "0083;5f5e1000;Safari;")                           // and the original keeps its own
    }

    @Test func anOlderCopyIsReplacedAndNothingIsLeftBehind() throws {
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Applications")
        _ = try AppCopier.install(app: try makeApp(in: root.appendingPathComponent("old"), marker: "old"), into: [folder])
        let result = try AppCopier.install(app: try makeApp(in: root.appendingPathComponent("new"), marker: "new"), into: [folder])
        #expect(try String(contentsOf: result.url.appendingPathComponent("Contents/MacOS/VoiceIt"), encoding: .utf8) == "binary new")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["Voice It.app"])    // no staging copy, no hidden leftovers
    }

    @Test func aFolderThatRefusesIsSkippedAndTheNextOneIsUsed() throws {
        let root = scratch(); defer { chmod(root.appendingPathComponent("locked").path, 0o755); try? FileManager.default.removeItem(at: root) }
        let app = try makeApp(in: root.appendingPathComponent("Downloads"))
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        chmod(locked.path, 0o555)                                                                         // like /Applications for a standard account
        let result = try AppCopier.install(app: app, into: [locked, root.appendingPathComponent("home/Applications")])
        #expect(result.usedFallback && result.url.path.contains("home/Applications"))
        #expect(!FileManager.default.fileExists(atPath: locked.appendingPathComponent("Voice It.app").path))
    }

    @Test func ifNothingAcceptsItTheErrorSaysSoAndNothingChanges() throws {
        let root = scratch(); defer { chmod(root.appendingPathComponent("locked").path, 0o755); try? FileManager.default.removeItem(at: root) }
        let app = try makeApp(in: root.appendingPathComponent("Downloads"))
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        chmod(locked.path, 0o555)
        do { _ = try AppCopier.install(app: app, into: [locked]); Issue.record("should have failed") }
        catch let e as AppCopier.CopyError { #expect(e.description.contains("drag it there yourself")) }
        #expect(FileManager.default.fileExists(atPath: app.path))
    }
}
