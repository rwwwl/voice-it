import Foundation

/// Names used in folders, logs and messages, in one place. (The bundle identifier, app file name and signing live in
/// Config/app.env and reach the running app through Info.plist.)
public enum AppIdentity {
    /// Shown to users, and the folder name under Application Support and Logs.
    public static let name = "Voice It"
    public static let logFileName = "voice-it.log"
    /// Used when the app isn't running from its own bundle (tests, the command-line harness).
    public static let defaultBundleID = "io.github.rwwwl.voice-it"

    /// "0.1.0 (build 52, abc1234)" from the app's Info.plist; a placeholder when run outside the app.
    public static var versionDescription: String {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let version = info["CFBundleShortVersionString"] as? String else { return "development build" }
        let build = info["CFBundleVersion"] as? String ?? "?"
        let commit = info["VoiceItCommit"] as? String ?? "unknown"
        return "\(version) (build \(build), \(commit))"
    }
}
