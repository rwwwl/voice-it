import Foundation

/// Launch at login, done with a per-user launch agent (a small property-list file in ~/Library/LaunchAgents) that opens the app.
/// Apple's newer SMAppService reported "not available" for this app, so this plain method is used instead. Nothing is installed
/// until the user switches it on, and switching it off deletes the file.
public enum LoginItem {
    /// The app sets this from its own bundle identifier at launch, so a rebuilt-under-another-ID copy never shares a login item with this one.
    public nonisolated(unsafe) static var label = AppIdentity.defaultBundleID + ".login"

    public static func agentURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// The property list: run `open -g -a <app>` at login. `open` goes through Launch Services, so the app starts exactly as if
    /// it had been double-clicked (its permissions apply), `-g` keeps it from taking the foreground, and if it is already
    /// running nothing happens.
    public static func plist(appPath: String) -> Data {
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-g", "-a", appPath],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
        ]
        return (try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)) ?? Data()
    }

    /// The app path a launch-agent file opens, or nil if there is no readable file.
    public static func appPath(in plistData: Data) -> String? {
        guard let dict = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let args = dict["ProgramArguments"] as? [String] else { return nil }
        return args.last
    }

    /// On only if the file exists and points at this app (a copy of the app elsewhere doesn't count as on).
    public static func isEnabled(for appPath: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        guard let data = try? Data(contentsOf: agentURL(home: home)) else { return false }
        return Self.appPath(in: data) == appPath
    }

    @discardableResult
    public static func enable(appPath: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let url = agentURL(home: home)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try plist(appPath: appPath).write(to: url, options: .atomic)
            return true
        } catch { Log.info("launch at login: could not write \(url.path): \(error)"); return false }
    }

    @discardableResult
    public static func disable(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        do { try FileManager.default.removeItem(at: agentURL(home: home)); return true }
        catch { return !FileManager.default.fileExists(atPath: agentURL(home: home).path) }
    }
}
