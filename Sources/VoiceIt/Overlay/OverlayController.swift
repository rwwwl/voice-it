import AppKit
import VoiceItCore
import SwiftUI

/// A panel that never takes keyboard focus, so a paste can't land in the wrong app.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets the X button work on the first click even though the panel is never key.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class OverlayController {
    private let model = OverlayModel()
    private let panel: OverlayPanel
    private var hideWork: DispatchWorkItem?
    private var showWork: DispatchWorkItem?
    private var demo: [DispatchWorkItem] = []

    /// How long after the key press the pill first appears: quick taps are ignored, so they shouldn't flash it either.
    static let showDelay: TimeInterval = Defaults.minHoldDuration
    /// How long an edge-state pill (red or amber) stays before it fades. Loading is the exception: it stays until the models are ready.
    static let edgeStateDuration: TimeInterval = 5

    var onCancel: () -> Void = {} { didSet { model.onCancel = onCancel } }
    /// The Done button (hands-free).
    var onDone: () -> Void = {} { didSet { model.onDone = onDone } }
    /// The style chip text of the recording on screen, kept so hands-free and its countdown can redraw the same pill.
    private var listeningChip: String?
    /// The "Open settings" chip: the app opens the pane; the pill then goes away.
    var onAction: (PillAction) -> Void = { _ in }
    /// Live microphone bands.
    var liveLevels: () -> [Float] = { [] }
    private var previewing = false
    private var loadingModels = false

    init() {
        panel = OverlayPanel(contentRect: NSRect(origin: .zero, size: OverlayView.size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.contentView = FirstClickHostingView(rootView: OverlayView(model: model))
        model.spectrum.levels = { [unowned self] in self.previewing ? Self.demoLevels() : self.liveLevels() }
        model.onAction = { [unowned self] action in self.onAction(action); self.hide(after: 0) }
    }

    // MARK: Used by the dictation flow

    /// Key went down. Shows the listening pill after `showDelay`, or at once if the pill is still on screen from the last dictation.
    func listeningBegan(chip: String? = nil) {
        cancelHide(); cancelDemo(); previewing = false
        showWork?.cancel()
        listeningChip = chip
        if model.visible { set(.listening(chip: chip)); return }
        let work = DispatchWorkItem { [weak self] in self?.set(.listening(chip: chip)) }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.showDelay, execute: work)
    }

    /// The hold turned into hands-free: the same pill gains the Done and X buttons.
    func handsFreeBegan() {
        cancelHide(); showWork?.cancel(); previewing = false
        set(.listening(chip: listeningChip, handsFree: true))
    }

    /// Hands-free is about to stop by itself.
    func handsFreeWarning(secondsLeft: Int) {
        guard model.visible, case .listening(_, true, _) = model.state else { return }
        set(.listening(chip: listeningChip, handsFree: true, warning: "Stops in \(secondsLeft) s"))
    }

    /// Models are loading (at launch). The pill appears only if it takes more than a second, so a quick start doesn't flash it.
    func loadingBegan() {
        loadingModels = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.loadingModels, !self.model.visible else { return }   // not over a dictation or a message
            self.set(.loading)
        }
    }

    func loadingEnded() {
        loadingModels = false
        if case .loading = model.state, model.visible { hide(after: 0) }
    }

    /// A dictation is waiting for the models to finish loading.
    func waitingForModel() { cancelHide(); showWork?.cancel(); if model.visible { set(.loading) } }

    /// A red pill for something the user has to fix. Hides itself, or on Escape, or when the chip is clicked.
    func blocked(_ message: String, action: PillAction?, duration: TimeInterval = OverlayController.edgeStateDuration) {
        cancelHide(); cancelDemo(); showWork?.cancel(); previewing = false
        set(.blocked(message, action: action))
        hide(after: duration)
    }

    /// Escape dismisses a message pill (never the listening or processing pills; a dictation is cancelled by its own key-down).
    func escapePressed() {
        guard model.visible else { return }
        switch model.state {
        case .blocked, .notice: hide(after: 0)
        default: break
        }
    }

    func processing() { cancelHide(); showWork?.cancel(); if model.visible { set(.processing) } }

    func finished(_ outcome: DictationOutcomeKind) {
        cancelHide(); showWork?.cancel()
        switch outcome {
        case .pasted: set(.done); hide(after: 1.0)
        case .copied: set(.copied); hide(after: 1.0)
        case .noSpeech: set(.noSpeech); model.shake += 1; hide(after: 1.4)
        case .notice(let m): set(.notice(m)); hide(after: Self.edgeStateDuration)
        case .blocked(let m, let action): blocked(m, action: action)
        }
    }

    /// The recording ended with nothing to transcribe (tap, cancel). Fades out if it was showing.
    func dismissed() { showWork?.cancel(); hide(after: 0) }

    // MARK: Preview (menu), so the look can be checked without dictating

    func preview(_ step: PreviewStep) {
        cancelDemo(); cancelHide(); showWork?.cancel()
        previewing = true
        switch step {
        case .listening: set(.listening(chip: nil)); schedule(&demo, 6) { [weak self] in self?.hide(after: 0) }
        case .listeningWithChip: set(.listening(chip: "Polished")); schedule(&demo, 6) { [weak self] in self?.hide(after: 0) }
        case .handsFree: set(.listening(chip: nil, handsFree: true)); schedule(&demo, 8) { [weak self] in self?.hide(after: 0) }
        case .handsFreeWarning: set(.listening(chip: "Polished", handsFree: true, warning: "Stops in 29 s")); schedule(&demo, 8) { [weak self] in self?.hide(after: 0) }
        case .processing: set(.processing); schedule(&demo, 6.5) { [weak self] in self?.hide(after: 0) }
        case .done: set(.done); hide(after: 1.0)
        case .copied: set(.copied); hide(after: 1.0)
        case .noSpeech: set(.noSpeech); model.shake += 1; hide(after: 1.4)
        case .loading: set(.loading); hide(after: 6)
        case .micBlocked: blocked("Mic access is off", action: .openMicrophone)
        case .accessibilityBlocked: blocked("Accessibility is off, text copied", action: .openAccessibility)
        case .inputMonitoringBlocked: blocked("Input Monitoring is off", action: .openInputMonitoring)
        case .modelFailed: blocked("Couldn't load the speech model", action: nil)
        case .cleanupSkipped: set(.notice("Pasted without cleanup")); hide(after: Self.edgeStateDuration)
        case .passwordField: set(.notice("Can't dictate into a password field")); hide(after: Self.edgeStateDuration)
        case .switchedApps: set(.notice("Switched apps, text copied")); hide(after: Self.edgeStateDuration)
        case .sequence:
            set(.listening(chip: nil))
            schedule(&demo, 3.0) { [weak self] in self?.set(.processing) }
            schedule(&demo, 6.4) { [weak self] in self?.set(.done) }
            schedule(&demo, 7.6) { [weak self] in self?.hide(after: 0) }
        }
    }

    private static func demoLevels() -> [Float] {
        let t = ProcessInfo.processInfo.systemUptime * 1000
        let s = max(0, sin(t * 0.0045) * 0.8 + 0.4 + sin(t * 0.011) * 0.2)
        func gauss(_ i: Double, _ c: Double, _ w: Double) -> Double { exp(-pow((i - c) / w, 2)) }
        return (0..<16).map { n in
            let i = Double(n)
            let spec = 0.1 + 0.45 * exp(-i / 4.5) + 0.55 * gauss(i, 2.5 + sin(t * 0.0021), 1.2)
                + 0.45 * gauss(i, 6 + 1.5 * sin(t * 0.0017 + 1), 1.5) + 0.3 * gauss(i, 10.5 + sin(t * 0.0013 + 2), 1.8)
            return Float(min(1, s * spec * (0.85 + 0.15 * sin(t * 0.02 + i * 1.3))) * 0.8)
        }
    }

    // MARK: Showing and hiding

    private func set(_ state: OverlayState) {
        let wasVisible = model.visible
        if !wasVisible { model.spectrum.reset(); place(); panel.orderFrontRegardless() }
        model.state = state
        panel.ignoresMouseEvents = !state.isClickable      // only the X and the Open settings chip need clicks
        if !wasVisible { DispatchQueue.main.async { self.model.visible = true } }   // next turn, so the fade-in animates
    }

    private func hide(after delay: TimeInterval) {
        cancelHide()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.model.visible = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if !self.model.visible { self.panel.orderOut(nil) }
            }
        }
        hideWork = work
        if delay == 0 { work.perform() } else { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }
        if !demo.isEmpty && delay == 0 { demo.removeAll() }
    }

    private func cancelHide() { hideWork?.cancel(); hideWork = nil }

    private func cancelDemo() { demo.forEach { $0.cancel() }; demo.removeAll() }

    private func schedule(_ list: inout [DispatchWorkItem], _ after: TimeInterval, _ block: @escaping () -> Void) {
        let w = DispatchWorkItem(block: block)
        list.append(w)
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: w)
    }

    /// Bottom centre of the display showing the focused window (the topmost window of the frontmost app), or of the display under
    /// the mouse pointer if there is no such window (for example the Finder with no windows open).
    private func place() {
        let byWindow = screenOfFocusedWindow()
        let screen = byWindow ?? screenUnderMouse()
        lastPlacement = "display \(NSScreen.screens.firstIndex(of: screen).map { $0 + 1 } ?? 0) of \(NSScreen.screens.count), chosen by \(byWindow != nil ? "the focused window" : "the pointer")"
        let f = screen.visibleFrame
        panel.setFrame(NSRect(x: f.midX - OverlayView.size.width / 2, y: f.minY, width: OverlayView.size.width, height: OverlayView.size.height), display: false)
    }

    private func screenUnderMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func screenOfFocusedWindow() -> NSScreen? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let primary = NSScreen.screens.first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        // The list is ordered front to back. Window bounds need no Screen Recording permission (only window titles do).
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (w[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  ((w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  var rect = CGRect(dictionaryRepresentation: dict as CFDictionary),
                  rect.width > 50, rect.height > 50
            else { continue }
            rect.origin.y = primary.frame.height - rect.maxY          // window list: origin top-left; AppKit: origin bottom-left
            if let i = ScreenPicker.index(forWindow: rect, screens: NSScreen.screens.map(\.frame)) { return NSScreen.screens[i] }
        }
        return nil
    }

    /// For the developer self-tests.
    private(set) var lastPlacement = ""
    var debugDescription: String { "\(model.state), visible \(model.visible); placed on \(lastPlacement)" }
}

enum DictationOutcomeKind { case pasted, copied, noSpeech, notice(String), blocked(String, PillAction?) }
enum PreviewStep {
    case listening, listeningWithChip, handsFree, handsFreeWarning, processing, done, copied, noSpeech, sequence
    case loading, micBlocked, accessibilityBlocked, inputMonitoringBlocked, modelFailed, cleanupSkipped, passwordField, switchedApps
}
