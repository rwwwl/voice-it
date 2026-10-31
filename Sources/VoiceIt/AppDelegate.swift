import AppKit
import VoiceItCore
import VoiceItDownloader

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let monitor = HotkeyMonitor()
    private let controller = HoldToTalkController()
    private let configStore = ConfigStore()
    private lazy var pipeline = DictationPipeline(
        transcriber: FluidAudioTranscriber(),
        cleaner: MLXCleaner(modelDirectory: configStore.current().cleanupModelDirectory),
        configStore: configStore)
    private let overlay = OverlayController()
    private lazy var vocabulary = VocabularyWindowController(store: configStore)
    private lazy var setup: SetupWindowController = MainActor.assumeIsolated { SetupWindowController(services: .init(
        speechLoad: { [weak self] in self?.speechLoadState ?? .notStarted },
        startLoadingSpeechModel: { [weak self] in self?.startSpeechLoading() },
        modelsChanged: { [weak self] in self?.modelsChanged() },
        hotkey: { [weak self] in self?.monitor.hotkey ?? .rightOption },
        copyModifier: { [weak self] in self?.monitor.copyModifier ?? .rightCommand },
        hotkeyActive: { [weak self] in self?.monitor.isActive ?? false })) }
    private let manifest = try? ModelManifest.bundled()
    private var speechLoadStarted = false
    /// The requirements check from launch (Apple silicon, macOS, memory). Free disk is only checked while downloading models.
    private var requirements = Requirements.check(facts: Requirements.currentFacts(at: Paths.applicationSupport), models: .withCleanup, checkDisk: false)
    private var unsupported = false
    private var retryTimer: Timer?
    private enum ModelState { case loading, ready(speech: Double, cleanup: Double?), failed(String) }
    private var model: ModelState = .loading { didSet { updateIcon() } }
    private var busy = false { didSet { updateIcon() } }
    /// Timings of the last dictation, for Advanced. Its text is blanked: the words live only in `lastDictation`.
    private var lastReport: DictationPipeline.Report?
    private let lastDictation = LastDictationStore()
    private var state: HoldToTalkController.State = .idle { didSet { updateIcon() } }
    /// The settings-file problem last announced, so the pill appears when a problem starts, not every two seconds.
    private var announcedProblem: ConfigProblem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The launch-agent label follows this copy's own bundle identifier.
        LoginItem.label = (Bundle.main.bundleIdentifier ?? AppIdentity.defaultBundleID) + ".login"
        let v = ProcessInfo.processInfo.operatingSystemVersion
        Log.info("\(AppIdentity.name) \(AppIdentity.versionDescription) launched on macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion); mic=\(Permissions.microphone) inputMonitoring=\(Permissions.inputMonitoring) accessibility=\(Permissions.accessibility)")
        AudioRecorder.clearTemporaryFiles()

        installEditMenu()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        overlay.liveLevels = { [weak self] in self?.controller.spectrumLevels() ?? [] }
        overlay.onCancel = { [weak self] in self?.controller.cancel() }
        overlay.onDone = { [weak self] in self?.controller.finish() }
        overlay.onAction = { action in
            switch action {
            case .openMicrophone: Permissions.openMicrophoneSettings()
            case .openAccessibility: Permissions.openAccessibilitySettings()
            case .openInputMonitoring: Permissions.openInputMonitoringSettings()
            case .openSettingsFile: NSWorkspace.shared.open(ConfigStore.url)
            }
        }
        controller.onState = { [weak self] in self?.handle($0) }
        controller.onRecording = { [weak self] result, _, releasedAt, target, copyOnly in
            self?.pipeline.enqueue(result, releasedAt: releasedAt, targetApp: target, copyOnly: copyOnly)
        }
        monitor.hotkey = configStore.current().hotkey
        monitor.copyModifier = configStore.current().copyModifier
        Log.info("hotkey: hold \(monitor.hotkey.displayName)")
        // Edits to config.json apply as soon as the file is saved, without restarting. A slow check remains as a safety net
        // (for example if the settings folder is deleted and recreated, which the folder watch would not follow).
        configStore.onChange = { [weak self] in self?.applySettings() }
        configStore.startWatching()
        let safetyNet = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.applySettings() }
        safetyNet.tolerance = 30
        checkSettingsFile()
        monitor.onEvent = { [weak self] event in
            if event == .escape { self?.overlay.escapePressed() }
            self?.controller.handle(event)
        }
        pipeline.onStatus = { [weak self] in self?.handle($0) }

        // Does this Mac meet the requirements? If not, say exactly what and stop rather than fail later in a confusing way.
        var facts = Requirements.currentFacts(at: Paths.applicationSupport)
        #if DEV_TOOLS
        if CommandLine.arguments.contains("--simulate-unsupported") { facts.isAppleSilicon = false }   // dev flag
        #endif
        requirements = Requirements.check(facts: facts, models: configStore.current().style == .exact ? .speechOnly : .withCleanup, checkDisk: false)
        for r in requirements.results where r.status != .ok { Log.info("requirements: \(r.status.rawValue): \(r.message)") }
        unsupported = !requirements.canContinue
        let setupDone = UserDefaults.standard.bool(forKey: "setupDone")
        let allAllowed = Permissions.microphone == .granted && Permissions.inputMonitoring && Permissions.accessibility
        // Relaunched by the setup window after it copied the app to Applications: carry on where it left off.
        let afterMove = CommandLine.arguments.contains("--setup-after-move")
        let movedFrom = CommandLine.arguments.firstIndex(of: "--moved-from").flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }
        let openSetup = !unsupported && (afterMove || SetupPlan.shouldOpenAtLaunch(speechInstalled: speechInstalled, setupDone: setupDone, allPermissionsGranted: allAllowed))
        Log.info("models installed: speech \(speechInstalled ? "yes" : "no"), cleanup \(pipeline.cleanupModelInstalled ? "yes" : "no")")
        if unsupported {
            overlay.blocked(requirements.failures[0].short, action: nil)
        } else if speechInstalled {
            startSpeechLoading()
            if !setupDone && allAllowed { UserDefaults.standard.set(true, forKey: "setupDone") }      // already set up and working: nothing to ask
        }
        // The app never asks for a permission on its own. A system prompt appears only when the person clicks that permission in the setup
        // window's Permissions step (or "Fix permissions…" in the menu); until then a pill and the menu say what is off.
        if openSetup {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.setup.show(startAt: afterMove ? .requirements : (setupDone ? .models : .welcome), movedFrom: movedFrom) } }
        }
        if !unsupported { startHotkeyWhenPossible() }
        // Say so at launch if the hotkey can't work yet (the most likely first-run problem), or the mic is off. One message at most.
        if unsupported {
            // already said above
        } else if !Permissions.inputMonitoring {
            overlay.blocked("Input Monitoring is off", action: .openInputMonitoring)
        } else if Permissions.microphone == .denied {
            overlay.blocked("Mic access is off", action: .openMicrophone)
        }
        observeSleepAndWake()
        Log.info("launch at login: \(LoginItem.isEnabled(for: Bundle.main.bundlePath) ? "on" : "off") (\(Bundle.main.bundlePath))")
        runDevFlags()
    }

    #if DEV_TOOLS
    /// Hidden switches for trying the app without the real trigger (a sleep, a sticky pill, a window). Compiled in only when
    /// DEV_TOOLS is set, which the shared build leaves out (see scripts/build.sh).
    private func runDevFlags() {
        if CommandLine.arguments.contains("--simulate-wake") {   // dev flag: exercise the wake handling without sleeping the Mac
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
            }
        }
        if CommandLine.arguments.contains("--simulate-overlap") {   // dev flag: a new dictation starts while "Pasted" is still showing
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.overlay.finished(.pasted) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { self.overlay.listeningBegan() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { Log.info("overlap test, 2.1 s after the new dictation began (the old pill would have faded at +1.0 s): \(self.overlay.debugDescription)") }
        }
        if CommandLine.arguments.contains("--preview-all") {   // dev flag: cycle through every overlay state, 2.5 s each
            let all: [PreviewStep] = [.listening, .processing, .done, .noSpeech, .loading, .modelFailed, .micBlocked, .accessibilityBlocked,
                                      .inputMonitoringBlocked, .cleanupSkipped, .passwordField, .switchedApps]
            for (i, step) in all.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2 + Double(i) * 2.5) { Log.info("preview: \(step)"); self.overlay.preview(step) }
            }
        }
        if CommandLine.arguments.contains("--selftest-drag") {   // dev flag: really drag the icon onto the folder (moves the cursor)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated { self.setup.show(startAt: .moveToApplications); self.setup.debugDrag() } }
        }
        if CommandLine.arguments.contains("--selftest-move") {   // dev flag: copy the app to VOICEIT_APPLICATIONS_DIR and relaunch it from there
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated { self.setup.show(startAt: .moveToApplications); self.setup.debugMove() } }
        }
        if CommandLine.arguments.contains("--selftest-paste") {   // dev flag: does a paste land in the setup window's practice box?
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated { self.setup.show(startAt: .tryIt); self.setup.debugPasteTest() } }
        }
        if CommandLine.arguments.contains("--setup-auto") {   // dev flag: with --show-setup or a fresh install, start the download by itself
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated { self.setup.debugStartDownload() } }
        }
        if CommandLine.arguments.contains("--show-setup") {   // dev flag: open the setup window at launch
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { self.setup.show() } }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render-setup"), i + 1 < CommandLine.arguments.count {   // dev flag: draw every setup step to PNGs and quit
            let folder = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            DispatchQueue.main.async { MainActor.assumeIsolated { renderSetupScreens(to: folder) }; exit(0) }
        }
        if CommandLine.arguments.contains("--show-vocabulary") {   // dev flag: open the Vocabulary window at launch
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.vocabulary.show() }
        }
        if CommandLine.arguments.contains("--preview-overlay") {   // dev flag: play the overlay sequence at launch
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.overlay.preview(.sequence) }
        }
    }
    #else
    private func runDevFlags() {}
    #endif

    private func handle(_ newState: HoldToTalkController.State) {
        switch newState {
        case .recording:
            // The style chip only shows under Automatic by app, for an app whose style isn't Natural: it explains why this app behaves differently.
            let config = configStore.current()
            let style = config.effectiveStyle(forApp: controller.targetApp)
            overlay.listeningBegan(chip: config.style == .automatic && style != .natural ? style.displayName : nil)
            pipeline.prepareForDictation(targetApp: controller.targetApp)
        case .handsFree: overlay.handsFreeBegan()
        case .handsFreeWarning(let left): overlay.handsFreeWarning(secondsLeft: left)
        case .discarded: overlay.dismissed()
        case .micBlocked: overlay.blocked("Mic access is off", action: .openMicrophone)
        case .passwordField: overlay.finished(.notice("Can't dictate into a password field"))
        case .idle: break
        }
        switch newState {
        case .discarded, .passwordField: state = .idle
        case .handsFreeWarning: break          // still hands-free: only the pill's countdown changes
        default: state = newState
        }
    }

    private func handle(_ status: DictationPipeline.Status) {
        switch status {
        case .modelLoading: model = .loading; overlay.loadingBegan()
        case .modelReady(let speech, let cleanup): model = .ready(speech: speech, cleanup: cleanup); overlay.loadingEnded()
        case .modelFailed(let e):
            model = .failed(e)
            overlay.loadingEnded()
            overlay.blocked("Couldn't load the speech model", action: nil)
        // A newer dictation may already be recording while an older one finishes. Its pill and sounds must not take over.
        case .transcribing: busy = true; if !isCapturing { overlay.processing() }
        case .waitingForModel: busy = true; if !isCapturing { overlay.waitingForModel() }
        case .finished(let report):
            busy = false
            // The words are remembered only for dictations that may be (never a password field). The kept report has no text in it.
            if report.outcome.isStorable {
                lastDictation.record(raw: report.rawText, text: report.text, history: configStore.current().history.enabled)
            }
            lastReport = DictationPipeline.Report(text: "", rawText: "", outcome: report.outcome, style: report.style, audioDuration: report.audioDuration,
                                                  tail: report.tail, waitedForModel: report.waitedForModel, transcribe: report.transcribe,
                                                  cleanup: report.cleanup, releaseToPaste: report.releaseToPaste, residentMB: report.residentMB, modelUse: report.modelUse)
            guard !isCapturing else { break }      // a newer dictation is recording: leave its pill and the microphone alone
            switch report.outcome {
            case .pasted: overlay.finished(.pasted)
            case .copied: overlay.finished(.copied)
            case .pastedWithoutCleanup: overlay.finished(.notice("Pasted without cleanup"))
            case .noSpeech: overlay.finished(.noSpeech)
            case .copiedNoAccessibility: overlay.finished(.blocked("Accessibility is off, text copied", .openAccessibility))
            case .blockedPasswordField: overlay.finished(.notice("Can't dictate into a password field"))
            case .copiedAppChanged: overlay.finished(.notice("Switched apps, text copied"))
            case .failed: overlay.finished(.notice("Couldn't transcribe"))
            }
        }
    }

    // MARK: Sleep and wake

    private func observeSleepAndWake() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.willSleep() }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.didWake() }
    }

    private func willSleep() {
        Log.info("going to sleep")
        controller.interrupt()       // a hold can't continue across sleep; a hands-free recording is processed so nothing said is lost
        overlay.dismissed()
    }

    /// After sleep the hotkey's event tap can be left stale, so it is torn down and built again. The microphone needs nothing:
    /// every recording starts a fresh audio engine, so a changed or sleeping input device is picked up automatically.
    private func didWake() {
        Log.info("woke from sleep: restarting the hotkey")
        retryTimer?.invalidate(); retryTimer = nil
        monitor.stop()
        updateIcon()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.startHotkeyWhenPossible() }
    }

    /// macOS creates the tap even without permission but then delivers no events, so check the permission first.
    private func startHotkeyWhenPossible() {
        if Permissions.inputMonitoring && monitor.start() { Log.info("hotkey active (\(monitor.hotkey.displayName))"); updateIcon(); return }
        Log.info("hotkey inactive: waiting for Input Monitoring permission")
        retryTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self, Permissions.inputMonitoring, self.monitor.start() else { return }
            Log.info("hotkey active (\(self.monitor.hotkey.displayName))")
            timer.invalidate()
            self.retryTimer = nil
            self.updateIcon()
        }
    }

    /// Brings the running app in line with the settings file. Cheap and safe to call at any time: each part does nothing unless its setting changed.
    private func applySettings() {
        let config = configStore.current()
        if config.hotkey != monitor.hotkey { monitor.hotkey = config.hotkey; Log.info("hotkey changed to \(config.hotkey.displayName)") }
        if config.copyModifier != monitor.copyModifier { monitor.copyModifier = config.copyModifier; Log.info("copy key changed to \(config.copyModifier.displayName)") }
        pipeline.syncCleanupModel()      // loads or frees the cleanup model to match the style and the Cleanup model setting
        pipeline.refreshCleanupPrompt()  // re-reads the model's instructions in the background after the vocabulary or style changed
        checkSettingsFile()
    }

    /// Says so (once) when the settings file has a mistake, and again if it changes to a different one. The last good settings stay in use.
    private func checkSettingsFile() {
        _ = configStore.current()
        let problem = configStore.problem
        guard problem != announcedProblem else { return }
        announcedProblem = problem
        if problem != nil { overlay.blocked("Settings error", action: .openSettingsFile) }
        updateIcon()
    }

    /// A recording is under way: holding the key, or hands-free.
    private var isCapturing: Bool { state == .recording || state == .handsFree }

    /// The menu bar icon has three looks (design/icons/MenuBar): the wave at rest, a filled badge while recording, and the struck-through
    /// wave when something needs fixing (settings error, speech model failed, microphone or Input Monitoring off). Loading and processing
    /// use the resting look: the pill already shows them.
    private func updateIcon() {
        let look: String, fallback: String
        if isCapturing { look = "recording"; fallback = "mic.fill" }
        else if configStore.problem != nil { look = "blocked"; fallback = "exclamationmark.triangle" }
        else if case .failed = model { look = "blocked"; fallback = "exclamationmark.triangle" }
        else if !speechInstalled { look = "blocked"; fallback = "mic.slash" }
        else if !monitor.isActive || state == .micBlocked { look = "blocked"; fallback = "mic.slash" }
        else { look = "idle"; fallback = "mic" }
        let image = NSImage(named: "menubar-\(look)") ?? NSImage(systemSymbolName: fallback, accessibilityDescription: AppIdentity.name)
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        statusItem.button?.image = image
        statusItem.button?.setAccessibilityLabel(AppIdentity.name)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let config = configStore.current()
        func label(_ text: String) { let i = NSMenuItem(title: text, action: nil, keyEquivalent: ""); i.isEnabled = false; menu.addItem(i) }
        @discardableResult
        func action(_ text: String, _ sel: Selector, to target: NSMenu? = nil, enabled: Bool = true) -> NSMenuItem {
            let i = NSMenuItem(title: text, action: sel, keyEquivalent: ""); i.target = self; i.isEnabled = enabled
            (target ?? menu).addItem(i); return i
        }
        func info(_ text: String, in sub: NSMenu) { let i = NSMenuItem(title: text, action: nil, keyEquivalent: ""); i.isEnabled = false; sub.addItem(i) }

        // Status
        var unsupportedReason: String?
        if unsupported { unsupportedReason = requirements.failures.first?.short }
        var modelFailed = false, modelLoading = false
        switch model { case .failed: modelFailed = true; case .loading: modelLoading = true; case .ready: break }
        let status = MenuStatus.decide(unsupported: unsupportedReason, settingsError: configStore.problem != nil,
                                       microphoneOff: Permissions.microphone == .denied, inputMonitoringOff: !monitor.isActive && !Permissions.inputMonitoring,
                                       modelFailed: modelFailed, modelLoading: modelLoading, setupNeeded: !speechInstalled)
        label(status.text)
        if let problem = configStore.problem {
            label("  \(problem.summary)")
            label("  Using your last good settings. Fix the file to apply changes.")
            action("Open settings file…", #selector(openConfig))
        }
        menu.addItem(.separator())

        // Style and Cleanup model
        let installed = pipeline.cleanupModelInstalled
        let styleItem = NSMenuItem(title: "Style", action: nil, keyEquivalent: "")
        let styleMenu = NSMenu()
        for choice in StyleChoice.allCases {
            let item = action(choice.displayName, #selector(setStyle(_:)), to: styleMenu, enabled: installed || choice == .exact)
            item.representedObject = StyleBox(choice)
            item.state = choice == config.style ? .on : .off
            if let fixed = choice.fixed { item.subtitle = fixed.summary } else { item.subtitle = "Each app has its own style" }
        }
        styleMenu.addItem(.separator())
        action("Edit app styles…", #selector(openConfig), to: styleMenu)
        if !installed {
            styleMenu.addItem(.separator())
            info("Cleanup model not installed: only Exact is available", in: styleMenu)
            action("Install cleanup model…", #selector(installCleanupModel), to: styleMenu)
        }
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)

        let memoryItem = NSMenuItem(title: "Cleanup model", action: nil, keyEquivalent: "")
        let memoryMenu = NSMenu()
        for memory in ModelMemory.allCases {
            let item = action(memory.displayName, #selector(setModelMemory(_:)), to: memoryMenu, enabled: installed)
            item.representedObject = MemoryBox(memory)
            item.state = memory == config.cleanup.memory ? .on : .off
            item.subtitle = memory == .keepReady ? "Loaded at launch, no waiting" : "Loads when needed, freed after \(config.cleanup.idleMinutes) minutes unused"
        }
        memoryItem.submenu = memoryMenu
        menu.addItem(memoryItem)
        menu.addItem(.separator())

        // Last dictation: one item that copies the cleaned text. The original words are under Advanced.
        let last = lastDictation.last(history: config.history.enabled)
        action("Copy last dictation", #selector(copyLast), enabled: last != nil)
        menu.addItem(.separator())

        // Permissions and launch
        let missing = missingPermissions()
        if missing.isEmpty { label("Permissions: all allowed") }
        else { action("Fix permissions… (\(missing.joined(separator: ", ")))", #selector(fixPermissions)) }
        let loginItem = action("Launch at login", #selector(toggleLaunchAtLogin))
        loginItem.state = LoginItem.isEnabled(for: Bundle.main.bundlePath) ? .on : .off
        menu.addItem(.separator())

        action("Vocabulary…", #selector(openVocabulary))
        action("Set up again…", #selector(openSetup))
        let repo = (Bundle.main.infoDictionary?["VoiceItRepoURL"] as? String) ?? ""
        if !repo.isEmpty { action("Help and report a problem…", #selector(openHelp)) }

        // Advanced: developer details (greyed, they are information) and the actions and switches that go with them.
        let advancedItem = NSMenuItem(title: "Advanced", action: nil, keyEquivalent: "")
        let adv = NSMenu()
        info("\(AppIdentity.name) \(AppIdentity.versionDescription)", in: adv)
        info(requirements.results.filter { $0.item != .disk }.map(\.short).joined(separator: ", "), in: adv)
        for r in requirements.results where r.status != .ok { info("Note: \(r.message)", in: adv) }
        switch model {
        case .loading: info("Speech model: loading…", in: adv)
        case .ready(let speech, _): info(String(format: "Speech model: ready (loaded in %.1f s)", speech), in: adv)
        case .failed(let e): info("Speech model: failed, \(e)", in: adv)
        }
        if !installed { info("Cleanup model: not installed", in: adv) }
        else if pipeline.cleanupModelReady { info("Cleanup model: \(config.cleanup.model), loaded", in: adv) }
        else if pipeline.cleanupModelLoading { info("Cleanup model: loading…", in: adv) }
        else { info(config.style == .exact ? "Cleanup model: not loaded (Exact style)" : "Cleanup model: not loaded (loads when needed)", in: adv) }
        info(monitor.isActive ? "Hotkey: hold \(monitor.hotkey.displayName)" : "Hotkey: off, needs Input Monitoring", in: adv)
        if let r = lastReport {
            switch r.outcome {
            case .pasted: info("Last dictation: pasted (\(r.style.displayName); \(r.modelUse))", in: adv)
            case .copied: info("Last dictation: copied to the clipboard on purpose (\(r.style.displayName); \(r.modelUse))", in: adv)
            case .pastedWithoutCleanup(let why): info("Last dictation: pasted without cleanup, \(why)", in: adv)
            case .noSpeech: info("Last dictation: no speech, nothing pasted", in: adv)
            case .copiedAppChanged: info("Last dictation: you switched apps, text copied", in: adv)
            case .copiedNoAccessibility: info("Last dictation: Accessibility is off, text copied", in: adv)
            case .blockedPasswordField: info("Last dictation: password field, nothing recorded or kept", in: adv)
            case .failed(let e): info("Last dictation: failed, \(e)", in: adv)
            }
            if let total = r.releaseToPaste {
                info(String(format: "  Release to Cmd-V %.0f ms (tail %.0f, transcribe %.0f, cleanup %.0f)", total * 1000, r.tail * 1000, r.transcribe * 1000, r.cleanup * 1000), in: adv)
            }
        } else {
            info("No dictation yet", in: adv)
        }
        info(String(format: "Memory in use: %.0f MB", Memory.megabytes().resident), in: adv)
        adv.addItem(.separator())
        action("Copy last dictation, original words", #selector(copyLastRaw), to: adv, enabled: !(last?.raw.isEmpty ?? true))
        action("Open settings file…", #selector(openConfig), to: adv)
        action("Open log…", #selector(openLog), to: adv)
        action("Open models folder…", #selector(openModelsFolder), to: adv)
        action("Licences…", #selector(openLicences), to: adv)
        adv.addItem(.separator())
        let saveAudio = action("Save audio from dictations", #selector(toggleSaveAudio), to: adv)
        saveAudio.state = config.debug.keepAudio ? .on : .off
        let logText = action("Log dictated text", #selector(toggleLogText), to: adv)
        logText.state = config.debug.logTranscripts ? .on : .off
        adv.addItem(.separator())
        let previewItem = NSMenuItem(title: "Preview overlay", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let steps: [(String, PreviewStep)] = [
            ("Play sequence", .sequence), ("Listening", .listening), ("Listening with style chip", .listeningWithChip),
            ("Hands-free", .handsFree), ("Hands-free, time running out", .handsFreeWarning),
            ("Processing", .processing), ("Done", .done), ("Copied", .copied), ("No speech", .noSpeech),
            ("Loading model", .loading), ("Couldn't load the model", .modelFailed),
            ("Mic blocked", .micBlocked), ("Accessibility blocked", .accessibilityBlocked), ("Input Monitoring blocked", .inputMonitoringBlocked),
            ("Pasted without cleanup", .cleanupSkipped), ("Password field", .passwordField), ("Switched apps", .switchedApps),
        ]
        for (title, step) in steps {
            let item = action(title, #selector(preview(_:)), to: sub)
            item.representedObject = PreviewBox(step)
        }
        previewItem.submenu = sub
        adv.addItem(previewItem)
        advancedItem.submenu = adv
        menu.addItem(advancedItem)

        action("About", #selector(showAbout))
        action("Quit", #selector(quit))
    }

    /// The permissions that are not granted yet, by name.
    private func missingPermissions() -> [String] {
        var missing: [String] = []
        if Permissions.microphone != .granted { missing.append("Microphone") }
        if !Permissions.inputMonitoring { missing.append("Input Monitoring") }
        if !Permissions.accessibility { missing.append("Accessibility") }
        return missing
    }

    /// Opens the settings pane for the first permission that is missing (or asks, if the microphone was never asked about).
    @objc private func fixPermissions() {
        if Permissions.microphone == .notDetermined { Permissions.requestMicrophone { _ in }; return }
        if Permissions.microphone == .denied { Permissions.openMicrophoneSettings() }
        else if !Permissions.inputMonitoring { Permissions.openInputMonitoringSettings() }
        else if !Permissions.accessibility { Permissions.openAccessibilitySettings() }
    }

    @objc private func preview(_ sender: NSMenuItem) { if let b = sender.representedObject as? PreviewBox { overlay.preview(b.step) } }
    /// Puts the last dictation's final text on the clipboard (for when it landed in the wrong place, or was only copied).
    @objc private func copyLast() {
        guard let t = lastDictation.last(history: configStore.current().history.enabled)?.text, !t.isEmpty else { return }
        MainActor.assumeIsolated { Paster.copyOnly(t, transient: false) }
        Log.info("copied last dictation to the clipboard")
    }
    @objc private func copyLastRaw() {
        guard let t = lastDictation.last(history: configStore.current().history.enabled)?.raw, !t.isEmpty else { return }
        MainActor.assumeIsolated { Paster.copyOnly(t, transient: false) }
        Log.info("copied last dictation, original words, to the clipboard")
    }
    @objc private func toggleSaveAudio() {
        if configStore.update({ $0.debug.keepAudio.toggle() }) { Log.info("save audio from dictations: \(configStore.current().debug.keepAudio ? "on" : "off")") }
    }
    @objc private func toggleLogText() {
        if configStore.update({ $0.debug.logTranscripts.toggle() }) { Log.info("log dictated text: \(configStore.current().debug.logTranscripts ? "on" : "off")") }
    }
    @objc private func openVocabulary() { vocabulary.show() }
    @objc private func openSetup() { MainActor.assumeIsolated { setup.show() } }
    @objc private func installCleanupModel() { MainActor.assumeIsolated { setup.show(startAt: .models, wantsCleanup: true) } }

    /// Voice It has no menu bar of its own (it lives in the status item), but its windows have text boxes, and a text box only handles
    /// Cut, Copy, Paste, Select All and Undo through the Edit menu's key equivalents. Without this, Cmd-V does nothing in the setup window's
    /// practice box or the Vocabulary window, including the Cmd-V the app itself sends after a dictation. The menu is never shown.
    private func installEditMenu() {
        let main = NSMenu()
        main.addItem(NSMenuItem())                      // the application menu slot (unused, there is no menu bar)
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        func add(_ title: String, _ action: String, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) {
            let item = edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
        }
        add("Undo", "undo:", "z"); add("Redo", "redo:", "z", [.command, .shift])
        edit.addItem(.separator())
        add("Cut", "cut:", "x"); add("Copy", "copy:", "c"); add("Paste", "paste:", "v"); add("Select All", "selectAll:", "a")
        editItem.submenu = edit
        main.addItem(editItem)
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    // MARK: Models and the setup window

    /// Is the speech model fully on disk? (Sizes only: the full checksum check happens when it is downloaded.)
    private var speechInstalled: Bool {
        manifest?.model("speech").map { ModelInstall.isComplete($0, root: Paths.modelsRoot) }
            ?? FileManager.default.fileExists(atPath: Paths.parakeetModels.appendingPathComponent("config.json").path)
    }

    private var speechLoadState: SetupModel.SpeechLoad {
        guard speechLoadStarted else { return .notStarted }
        switch model { case .loading: return .loading; case .ready(let seconds, _): return .ready(seconds: seconds); case .failed(let why): return .failed(why) }
    }

    private func startSpeechLoading() {
        speechLoadStarted = true
        pipeline.startLoading()
    }

    /// The setup window finished installing a model: start using it without a restart.
    private func modelsChanged() {
        if speechInstalled && !speechLoadStarted { startSpeechLoading() }
        applySettings()        // loads the cleanup model when the settings call for it
        updateIcon()
    }
    @objc private func openModelsFolder() {
        let folder = Paths.applicationSupport.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
    @objc private func openHelp() {
        if let s = Bundle.main.infoDictionary?["VoiceItRepoURL"] as? String, let url = URL(string: s + "/issues") { NSWorkspace.shared.open(url) }
    }
    @objc private func toggleLaunchAtLogin() {
        let path = Bundle.main.bundlePath
        if LoginItem.isEnabled(for: path) { LoginItem.disable() } else { LoginItem.enable(appPath: path) }
        Log.info("launch at login: \(LoginItem.isEnabled(for: path) ? "on" : "off") (\(path))")
    }

    @objc private func setStyle(_ sender: NSMenuItem) {
        guard let choice = (sender.representedObject as? StyleBox)?.choice else { return }
        if configStore.update({ $0.style = choice }) { Log.info("style set to \(choice.rawValue)") }
        applySettings()
    }

    @objc private func setModelMemory(_ sender: NSMenuItem) {
        guard let memory = (sender.representedObject as? MemoryBox)?.memory else { return }
        if configStore.update({ $0.cleanup.memory = memory }) { Log.info("cleanup model set to \(memory.rawValue)") }
        applySettings()
    }

    @objc private func openConfig() { _ = configStore.current(); NSWorkspace.shared.open(ConfigStore.url) }
    /// The standard About panel, with the version and commit, the licence and the credits the models and libraries require.
    @objc private func showAbout() {
        let info = Bundle.main.infoDictionary ?? [:]
        let sections = Attributions.sections(version: AppIdentity.versionDescription,
                                             copyrightHolder: info["VoiceItCopyrightHolder"] as? String ?? "the authors",
                                             year: info["VoiceItCopyrightYear"] as? String ?? "",
                                             repoURL: info["VoiceItRepoURL"] as? String)
        let credits = NSMutableAttributedString()
        for section in sections {
            credits.append(NSAttributedString(string: section.heading + "\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 11)]))
            credits.append(NSAttributedString(string: section.lines.joined(separator: "\n\n") + "\n\n", attributes: [.font: NSFont.systemFont(ofSize: 11)]))
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: AppIdentity.name, .credits: credits])
    }

    @objc private func openLicences() {
        if let url = Bundle.main.url(forResource: "THIRD_PARTY_LICENSES", withExtension: "md") { NSWorkspace.shared.open(url) }
    }

    @objc private func openLog() { NSWorkspace.shared.open(Log.url) }
    @objc private func openInputMonitoring() { Permissions.openInputMonitoringSettings() }
    @objc private func openMicrophone() { Permissions.openMicrophoneSettings() }
    @objc private func openAccessibility() { Permissions.openAccessibilitySettings() }
    @objc private func quit() { NSApp.terminate(nil) }
}

private final class PreviewBox { let step: PreviewStep; init(_ s: PreviewStep) { step = s } }
private final class StyleBox { let choice: StyleChoice; init(_ c: StyleChoice) { choice = c } }
private final class MemoryBox { let memory: ModelMemory; init(_ m: ModelMemory) { memory = m } }
