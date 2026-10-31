import AppKit
import Foundation

/// Joins the hotkey to the recorder. The rules (hold to talk, hands-free, taps, cancels) live in `HotkeyMachine`; this carries them out.
///
/// Hold to talk: press starts capture, release ends it (after an adaptive tail), short taps are discarded.
/// Adaptive tail: people often let go of the key a moment before they finish speaking. After release, recording
/// continues only while speech is still being heard, and stops after `Defaults.tailSilence` of quiet or `Defaults.tailMax`.
///
/// Hands-free: Shift added during the hold keeps recording after release, until Done, the hotkey again (both process the recording),
/// or X, Escape (both discard it). It stops by itself after `Defaults.handsFreeMax`, or `Defaults.handsFreeSilence` without speech.
public final class HoldToTalkController {
    /// `discarded`: a recording ended without anything to transcribe (short tap, cancelled, or failed to start).
    /// `idle`: a recording ended and was handed on, or nothing was happening.
    /// `handsFree`: the hold turned into a hands-free recording. `handsFreeWarning`: that many seconds until it stops by itself.
    public enum State: Equatable { case idle, recording, handsFree, handsFreeWarning(secondsLeft: Int), micBlocked, passwordField, discarded }

    public var onState: ((State) -> Void)?
    /// `releasedAt` is `ProcessInfo.systemUptime` at key release, the start of the latency clock.
    /// `targetApp` is the bundle ID of the app that was in front at key press (hands-free: when it was finished, since the
    /// words land wherever the person is by then).
    /// `copyOnly`: the text should be copied to the clipboard, not pasted (the copy modifier was held).
    public var onRecording: ((AudioRecorder.Result, _ holdDuration: TimeInterval, _ releasedAt: TimeInterval, _ targetApp: String?, _ copyOnly: Bool) -> Void)?

    /// Whether a password field has focus (macOS secure keyboard input). Replaceable for tests.
    public var secureInput: () -> Bool = { Paster.secureInputActive }

    private let recorder = AudioRecorder()
    private var machine = HotkeyMachine(minHold: Defaults.minHoldDuration)
    private var pressedAt: TimeInterval = 0
    /// Bundle ID of the app in front when the key went down (where the text is meant to land).
    public private(set) var targetApp: String?

    private var tailTimer: Timer?
    private var inTail = false
    private var releasedAt: TimeInterval = 0
    private var hold: TimeInterval = 0

    private var handsFreeTimer: Timer?
    private var handsFreeStartedAt: TimeInterval = 0
    private var lastWarningShown: Int?
    private var skipTail = false
    private var pendingCopyOnly = false

    public init() {}

    public var isHandsFree: Bool { machine.state == .handsFree }

    public func handle(_ event: HotkeyMonitor.Event) {
        let now = ProcessInfo.processInfo.systemUptime
        switch event {
        case .pressed(let shift, let copy):
            if inTail { finishTail() }   // a new dictation starts: close the previous one first
            apply(machine.handle(.hotkeyDown(shift: shift, copy: copy, at: now)))
        case .released: apply(machine.handle(.hotkeyUp(at: now)))
        case .shift(let down): apply(machine.handle(.shift(down: down)))
        case .copy(let down): apply(machine.handle(.copyModifier(down: down)))
        case .escape:
            // A hold is cancelled by Escape; hands-free too. (The overlay separately dismisses a message pill.)
            apply(machine.handle(.escape))
        case .cancelled:
            guard recorder.isRecording, !inTail else { return }
            apply(machine.handle(.otherKey))
        }
    }

    /// Latest spectrum bands for the overlay.
    public func spectrumLevels() -> [Float] { recorder.spectrumLevels() }

    /// The X button: nothing is transcribed or pasted.
    public func cancel() {
        if inTail {
            tailTimer?.invalidate(); tailTimer = nil
            inTail = false
            recorder.stop(keep: false)
            Log.info("recording cancelled (X button)")
            onState?(.discarded)
            return
        }
        apply(machine.handle(.cancelButton))
    }

    /// The Done button in hands-free mode: stop and process what was recorded.
    public func finish() { apply(machine.handle(.done)) }

    /// The Mac is going to sleep: a hold is dropped, a hands-free recording is processed so nothing said is lost.
    public func interrupt() {
        if inTail { finishTail() }
        skipTail = true; defer { skipTail = false }      // going to sleep: no time to wait for a last word
        apply(machine.handle(.interrupted))
    }

    // MARK: Carrying out what the machine decides

    private func apply(_ actions: [HotkeyMachine.Action]) {
        for action in actions {
            switch action {
            case .startRecording: startRecording()
            case .discardTap:
                recorder.stop(keep: false)
                Log.info(String(format: "tap ignored (held %.0f ms)", (ProcessInfo.processInfo.systemUptime - pressedAt) * 1000))
                onState?(.discarded)
            case .finishHold(let held, let copyOnly): pendingCopyOnly = copyOnly; beginTail(held: held)
            case .enterHandsFree: beginHandsFree()
            case .finishHandsFree: finishHandsFree()
            case .cancel:
                guard recorder.isRecording, !inTail else { continue }
                stopHandsFreeTimer()
                recorder.stop(keep: false)
                Log.info("recording cancelled")
                onState?(.discarded)
            }
        }
    }

    private func startRecording() {
        // In a password field nothing is recorded at all.
        if secureInput() {
            Log.info("a password field has focus; not recording")
            _ = machine.handle(.startFailed)
            onState?(.passwordField)
            return
        }
        switch Permissions.microphone {
        case .granted: break
        case .notDetermined:
            // Never asked yet: ask now (the system prompt explains itself), and don't record this time.
            Log.info("hotkey pressed before microphone access was asked for; asking now")
            Permissions.requestMicrophone { ok in Log.info("microphone prompt answered: \(ok ? "allowed" : "denied")") }
            _ = machine.handle(.startFailed)
            onState?(.discarded)
            return
        case .denied:
            Log.info("hotkey pressed but microphone access is off; not recording")
            _ = machine.handle(.startFailed)
            onState?(.micBlocked)
            return
        }
        pressedAt = ProcessInfo.processInfo.systemUptime
        targetApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        do {
            try recorder.start()
            Log.info("recording started")
            onState?(.recording)
        } catch {
            Log.info("could not start recording: \(error)")
            _ = machine.handle(.startFailed)
            onState?(.discarded)
        }
    }

    // MARK: Hold to talk: the adaptive tail

    private func beginTail(held: TimeInterval) {
        guard recorder.isRecording, !inTail else { onState?(.idle); return }
        releasedAt = ProcessInfo.processInfo.systemUptime
        hold = held
        inTail = true
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in self?.tailTick() }
        RunLoop.main.add(timer, forMode: .common)   // .common so it keeps running while a menu is open
        tailTimer = timer
        tailTick()
    }

    private func tailTick() {
        let sinceRelease = ProcessInfo.processInfo.systemUptime - releasedAt
        if recorder.silenceDuration() >= Defaults.tailSilence || sinceRelease >= Defaults.tailMax { finishTail() }
    }

    private func finishTail() {
        tailTimer?.invalidate(); tailTimer = nil
        guard inTail else { return }
        inTail = false
        let tail = ProcessInfo.processInfo.systemUptime - releasedAt
        hand(over: tail, label: "held")
    }

    // MARK: Hands-free

    private func beginHandsFree() {
        guard recorder.isRecording else { return }
        handsFreeStartedAt = ProcessInfo.processInfo.systemUptime
        lastWarningShown = nil
        Log.info("hands-free recording started")
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.handsFreeTick() }
        RunLoop.main.add(timer, forMode: .common)
        handsFreeTimer = timer
        onState?(.handsFree)
    }

    private func handsFreeTick() {
        let elapsed = ProcessInfo.processInfo.systemUptime - handsFreeStartedAt
        if elapsed >= Defaults.handsFreeMax {
            Log.info("hands-free stopped: reached the maximum length")
            apply(machine.handle(.autoStop)); return
        }
        if recorder.silenceDuration() >= Defaults.handsFreeSilence {
            Log.info("hands-free stopped: no speech for \(Int(Defaults.handsFreeSilence)) s")
            apply(machine.handle(.autoStop)); return
        }
        let left = Int((Defaults.handsFreeMax - elapsed).rounded(.up))
        if Double(left) <= Defaults.handsFreeWarning, left != lastWarningShown {
            lastWarningShown = left
            onState?(.handsFreeWarning(secondsLeft: left))
        }
    }

    private func stopHandsFreeTimer() { handsFreeTimer?.invalidate(); handsFreeTimer = nil }

    private func finishHandsFree() {
        stopHandsFreeTimer()
        guard recorder.isRecording else { onState?(.idle); return }
        let now = ProcessInfo.processInfo.systemUptime
        // The words land where the person is now, which may not be where they began.
        targetApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if skipTail {
            releasedAt = now; hold = now - pressedAt
            hand(over: 0, label: "hands-free")
        } else {
            // Same adaptive tail as hold to talk: the last word is often still being spoken as Done is clicked.
            beginTail(held: now - pressedAt)
        }
    }

    /// Stops the recorder and passes the recording on to be transcribed.
    private func hand(over tail: TimeInterval, label: String) {
        let copyOnly = pendingCopyOnly
        pendingCopyOnly = false
        guard var result = recorder.stop() else { onState?(.discarded); return }
        defer { onState?(.idle) }
        result.tail = tail
        if copyOnly { Log.info("copy only: the text will be copied, not pasted") }
        Log.info(String(format: "recording captured: %@ %.2f s, tail %.0f ms, audio %.2f s, peak %.0f dBFS, voiced %.2f s, start latency %@ ms, stop latency %.0f ms",
                        label, hold, tail * 1000, result.duration, result.peakDBFS, result.voicedDuration,
                        result.startLatency.map { String(format: "%.0f", $0 * 1000) } ?? "n/a", result.stopLatency * 1000))
        onRecording?(result, hold, releasedAt, targetApp, copyOnly)
    }
}
