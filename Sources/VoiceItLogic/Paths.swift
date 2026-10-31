import Foundation

public enum Paths {
    /// ~/Library/Application Support/Voice It. VOICEIT_SUPPORT_DIR points it somewhere else, so a fresh install can be tried without touching
    /// the real settings and models (a developer aid; the app never sets it).
    public static let applicationSupport: URL = {
        if let override = ProcessInfo.processInfo.environment["VOICEIT_SUPPORT_DIR"] { return URL(fileURLWithPath: override, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(AppIdentity.name, isDirectory: true)
    }()

    /// Where the downloaded models live (the folders in the model manifest are relative to this).
    public static var modelsRoot: URL { applicationSupport.appendingPathComponent("models", isDirectory: true) }

    /// Parakeet TDT v2 Core ML bundle. Override with VOICEIT_MODELS_DIR (used by the harness and tests).
    public static var parakeetModels: URL {
        if let override = ProcessInfo.processInfo.environment["VOICEIT_MODELS_DIR"] { return URL(fileURLWithPath: override) }
        return applicationSupport.appendingPathComponent("models/parakeet-tdt-0.6b-v2", isDirectory: true)
    }
}
