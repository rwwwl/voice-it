import AppKit
import SwiftUI
import VoiceItCore
import VoiceItDownloader

/// What the setup window shows and does. The decisions (which steps, what blocks, what to fetch) are in `SetupPlan`; this holds the live state.
@MainActor
final class SetupModel: ObservableObject {
    enum SpeechLoad: Equatable { case notStarted, loading, ready(seconds: Double), failed(String) }
    enum Download: Equatable { case idle, running, failed(String), done }
    enum Move: Equatable { case idle, copying, opening(URL, fellBack: Bool), failed(String) }

    /// What the window needs from the rest of the app.
    struct Services {
        var speechLoad: () -> SpeechLoad
        var startLoadingSpeechModel: () -> Void
        /// A model was installed: let the app start using it.
        var modelsChanged: () -> Void
        var hotkey: () -> Hotkey
        var copyModifier: () -> Hotkey
        var hotkeyActive: () -> Bool
    }

    @Published var step: SetupStep
    @Published private(set) var state = SetupState()
    @Published private(set) var requirements: RequirementsReport
    @Published var wantsCleanup: Bool { didSet { recheck() } }
    @Published private(set) var download = Download.idle
    @Published private(set) var progress: ModelDownloader.Progress?
    @Published private(set) var speechLoad = SpeechLoad.notStarted
    @Published private(set) var microphone = Permissions.Status.notDetermined
    @Published private(set) var hotkeyActive = false
    @Published var practiceText = ""
    @Published private(set) var move = Move.idle
    let location: AppLocation
    /// Where the app was before it was copied to Applications (shown once, after the relaunch).
    let movedFrom: String?

    let manifest: ModelManifest?
    let services: Services
    let hotkey: Hotkey
    let copyModifier: Hotkey
    var hotkeyName: String { hotkey.displayName }
    private let memoryBytes: UInt64
    private var task: Task<Void, Never>?
    private let live: Bool

    init(services: Services, manifest: ModelManifest? = try? ModelManifest.bundled(), startAt: SetupStep? = nil, wantsCleanup: Bool? = nil, live: Bool = true,
         location: AppLocation = AppPlacement.classify(bundlePath: Bundle.main.bundlePath, home: NSHomeDirectory()), movedFrom: String? = nil) {
        self.services = services
        self.location = location
        self.movedFrom = movedFrom
        self.manifest = manifest
        self.live = live
        memoryBytes = ProcessInfo.processInfo.physicalMemory
        hotkey = services.hotkey()
        copyModifier = services.copyModifier()
        step = startAt ?? .welcome
        self.wantsCleanup = wantsCleanup ?? SetupPlan.defaultWantsCleanup(memoryBytes: ProcessInfo.processInfo.physicalMemory)
        requirements = Requirements.check(facts: Requirements.currentFacts(at: Paths.applicationSupport), models: .speechOnly, checkDisk: false)
        if live { refresh() }
    }

    /// The Applications step is skipped when the app already sits in Applications.
    var steps: [SetupStep] { SetupStep.allCases.filter { $0 != .moveToApplications || AppPlacement.needsMove(location) } }
    var placeName: String { AppPlacement.friendlyPlace(of: Bundle.main.bundlePath, home: NSHomeDirectory()) }
    var canContinue: Bool { SetupPlan.canContinue(from: step, state) }
    var isLastStep: Bool { step == steps.last }
    var isFirstStep: Bool { step == steps.first }

    var speech: ModelManifest.Model? { manifest?.model("speech") }
    var cleanup: ModelManifest.Model? { manifest?.model("cleanup") }
    var speechInstalled: Bool { state.speechInstalled }
    var cleanupInstalled: Bool { state.cleanupInstalled }
    var permissionsAllGranted: Bool { state.microphoneGranted && state.inputMonitoringGranted && state.accessibilityGranted }
    var cleanupRecommended: Bool { memoryBytes >= Requirements.fullCleanupMemoryBytes }
    var memoryText: String { "\(Int((Double(memoryBytes) / Double(1 << 30)).rounded())) GB" }

    var idsToFetch: [String] { SetupPlan.modelsToFetch(speechInstalled: state.speechInstalled, cleanupInstalled: state.cleanupInstalled, wantsCleanup: wantsCleanup) }
    var bytesToFetch: Int64 { idsToFetch.compactMap { manifest?.model($0)?.totalBytes }.reduce(0, +) }

    // MARK: Keeping up with the Mac

    /// Re-reads everything the window shows. Called every second while it is open.
    func refresh() {
        guard live else { return }
        var s = state
        s.speechInstalled = speech.map { ModelInstall.isComplete($0, root: Paths.modelsRoot) } ?? false
        s.cleanupInstalled = cleanup.map { ModelInstall.isComplete($0, root: Paths.modelsRoot) } ?? false
        s.wantsCleanup = wantsCleanup
        speechLoad = services.speechLoad()
        if case .ready = speechLoad { s.speechModelReady = true } else { s.speechModelReady = false }
        microphone = Permissions.microphone
        s.microphoneGranted = microphone == .granted
        s.inputMonitoringGranted = Permissions.inputMonitoring
        s.accessibilityGranted = Permissions.accessibility
        hotkeyActive = services.hotkeyActive()
        s.requirementsCanContinue = requirements.canContinue
        if s != state { state = s }
        // The speech model starts loading as soon as it is on disk, and again if the person asks.
        if s.speechInstalled, speechLoad == .notStarted { services.startLoadingSpeechModel() }
    }

    func recheck() {
        guard live else { return }
        let needsDisk = !idsToFetch.isEmpty && download != .running
        requirements = Requirements.check(facts: Requirements.currentFacts(at: Paths.modelsRoot), models: wantsCleanup ? .withCleanup : .speechOnly, checkDisk: needsDisk)
        state.requirementsCanContinue = requirements.canContinue
    }

    // MARK: Moving between steps

    func next() {
        guard canContinue, let i = steps.firstIndex(of: step), i + 1 < steps.count else { return }
        step = steps[i + 1]
        if step == .requirements { recheck() }
    }
    func back() { if let i = steps.firstIndex(of: step), i > 0 { step = steps[i - 1] } }

    func finish() { UserDefaults.standard.set(true, forKey: "setupDone") }

    // MARK: Moving to Applications

    /// Copies the app to Applications (or ~/Applications if that refuses), opens the copy, and quits this one once the copy is running.
    /// The original is never moved, renamed or changed, and the quarantine mark is left as it is.
    func moveToApplications() {
        guard move != .copying else { return }
        move = .copying
        let source = Bundle.main.bundleURL
        Task.detached {
            do {
                let result = try AppCopier.install(app: source, into: AppPlacement.destinationFolders())
                await MainActor.run { [weak self] in self?.openCopy(result, original: source) }
            } catch {
                await MainActor.run { [weak self] in self?.move = .failed((error as? AppCopier.CopyError)?.description ?? error.localizedDescription) }
            }
        }
    }

    private func openCopy(_ result: AppCopier.Result, original: URL) {
        move = .opening(result.url, fellBack: result.usedFallback)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--setup-after-move", "--moved-from", original.path]
        NSWorkspace.shared.openApplication(at: result.url, configuration: configuration) { [weak self] app, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.move = .failed("A copy is in \(result.url.deletingLastPathComponent().path), but it wouldn't open (\(error.localizedDescription)). Open it from Finder; this window stays open.")
                    return
                }
                try? await Task.sleep(nanoseconds: 2_500_000_000)          // let the copy get going before this one goes
                if let app, !app.isTerminated { NSApp.terminate(nil) }
                else { self.move = .failed("The copy in \(result.url.deletingLastPathComponent().path) closed straight away. Open it from Finder; this window stays open.") }
            }
        }
    }

    // MARK: Downloading

    func startDownload() {
        guard download != .running else { return }
        guard let manifest else { download = .failed("The list of models is missing from this copy of Voice It, so it can't download them."); return }
        let models = idsToFetch.compactMap { manifest.model($0) }
        guard !models.isEmpty else { download = .done; return }
        recheck()
        guard requirements.canContinue else { download = .failed(requirements.failures.first?.message ?? "This Mac can't hold the models."); return }
        download = .running
        progress = nil
        task = Task { [weak self] in
            // A background menu bar app would otherwise be slowed down (App Nap) and the Mac may sleep in the middle of a 3 GB download.
            let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Downloading the Voice It models")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            do {
                try await ModelDownloader(root: Paths.modelsRoot).install(models) { p in Task { @MainActor [weak self] in self?.progress = p } }
                await MainActor.run { self?.downloadFinished() }
            } catch let e as ModelDownloader.DownloadError where e == .cancelled {
                await MainActor.run { self?.download = .idle }
            } catch {
                await MainActor.run { self?.download = .failed((error as? ModelDownloader.DownloadError)?.description ?? error.localizedDescription) }
            }
        }
    }

    private func downloadFinished() {
        download = .done
        refresh()
        services.modelsChanged()
        recheck()
    }

    /// The window was closed: stop fetching. What arrived is kept, and the next try carries on from it.
    func cancelDownload() { task?.cancel(); task = nil; if download == .running { download = .idle } }

    func retryLoad() { speechLoad = .loading; services.startLoadingSpeechModel() }

    func openModelsFolder() {
        try? FileManager.default.createDirectory(at: Paths.modelsRoot, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Paths.modelsRoot)
    }

    // MARK: Permissions

    // Nothing here is asked until the person clicks it. The first click raises the system's own prompt; if that is not enough (they declined it,
    // or macOS only offers a switch in System Settings), the next click opens the right pane instead. The label says which will happen.
    var microphoneButton: String { microphone == .notDetermined ? "Allow…" : "Open settings" }
    var inputMonitoringButton: String { askedInputMonitoring ? "Open settings" : "Allow…" }
    var accessibilityButton: String { askedAccessibility ? "Open settings" : "Allow…" }
    @Published private var askedInputMonitoring = UserDefaults.standard.bool(forKey: "askedInputMonitoring")
    @Published private var askedAccessibility = UserDefaults.standard.bool(forKey: "askedAccessibility")

    func allowMicrophone() {
        if Permissions.microphone == .notDetermined { Permissions.requestMicrophone { [weak self] _ in self?.refresh() } }
        else { Permissions.openMicrophoneSettings() }
    }
    func allowInputMonitoring() {
        if askedInputMonitoring { Permissions.openInputMonitoringSettings(); return }
        askedInputMonitoring = true; UserDefaults.standard.set(true, forKey: "askedInputMonitoring")
        _ = Permissions.requestInputMonitoring()
    }
    func allowAccessibility() {
        if askedAccessibility { Permissions.openAccessibilitySettings(); return }
        askedAccessibility = true; UserDefaults.standard.set(true, forKey: "askedAccessibility")
        _ = Permissions.requestAccessibility()
    }
}

extension SetupModel {
    /// A model filled with sample data, for rendering the window to an image without touching the Mac (a developer aid).
    static func preview(step: SetupStep, edit: (inout SetupState) -> Void = { _ in }, download: Download = .idle, progress: ModelDownloader.Progress? = nil,
                        speech: SpeechLoad = .notStarted, wantsCleanup: Bool = true, location: AppLocation = .applications, move: Move = .idle, movedFrom: String? = nil) -> SetupModel {
        let m = SetupModel(services: .init(speechLoad: { .notStarted }, startLoadingSpeechModel: {}, modelsChanged: {}, hotkey: { .rightOption }, copyModifier: { .rightCommand }, hotkeyActive: { true }),
                           startAt: step, wantsCleanup: wantsCleanup, live: false, location: location, movedFrom: movedFrom)
        var s = SetupState(); edit(&s); m.state = s
        m.download = download; m.progress = progress; m.speechLoad = speech; m.move = move
        m.requirements = Requirements.check(facts: Requirements.currentFacts(at: Paths.modelsRoot), models: wantsCleanup ? .withCleanup : .speechOnly, checkDisk: true)
        return m
    }
}
