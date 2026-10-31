import CoreGraphics
import Foundation

/// Listen-only event tap for hold-to-talk on a modifier key (right Option by default; see `Hotkey`).
/// Pressing any other key or modifier while it is held cancels, so Option-e and similar still type normally.
/// Shift (hands-free) and the copy modifier (copy instead of paste) are the exceptions: see `HotkeyMachine`.
public final class HotkeyMonitor {
    /// `escape`: the Escape key went down (any time, not only during a hold). Listen-only, so it still reaches the focused app.
    /// `pressed`: the key went down; `shift` and `copy` say whether Shift and the copy modifier were already down.
    /// `shift`, `copy`: that modifier changed while the key is held. `cancelled`: another key or modifier went down during a hold.
    public enum Event: Equatable { case pressed(shift: Bool, copy: Bool), released, shift(down: Bool), copy(down: Bool), cancelled, escape }

    public var onEvent: ((Event) -> Void)?
    public var isActive: Bool { tap != nil }
    /// Which key to hold. Changing it while the key is down cancels that hold.
    public var hotkey: Hotkey = .rightOption {
        didSet { if hotkey != oldValue { cancelIfDown() } }
    }

    /// Held with the hotkey, the text is copied instead of pasted. Never the same key as the hotkey.
    public var copyModifier: Hotkey = .rightCommand

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isDown = false

    public init() {}

    /// Returns false when the tap can't be created yet (Input Monitoring not granted).
    @discardableResult
    public func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon {
                Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    public func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil; source = nil; isDown = false
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            Log.info("event tap was disabled by the system; re-enabled")
            cancelIfDown()
        case .keyDown:
            if event.getIntegerValueField(.keyboardEventKeycode) == 53 { onEvent?(.escape) }
            cancelIfDown()
        case .flagsChanged:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == hotkey.keyCode {
                let down = event.flags.rawValue & hotkey.deviceMask != 0
                // With a Shift key as the hotkey there is no other Shift to add, so hands-free is simply unavailable.
                let shift = !hotkey.isShift && event.flags.contains(.maskShift)
                let copy = event.flags.rawValue & copyModifier.deviceMask != 0 && copyModifier != hotkey
                if down && !isDown { isDown = true; onEvent?(.pressed(shift: shift, copy: copy)) }
                else if !down && isDown { isDown = false; onEvent?(.released) }
            } else if (keyCode == 56 || keyCode == 60), !hotkey.isShift {
                if isDown { onEvent?(.shift(down: event.flags.contains(.maskShift))) }    // Shift never cancels a hold
            } else if keyCode == copyModifier.keyCode, copyModifier != hotkey {
                if isDown { onEvent?(.copy(down: event.flags.rawValue & copyModifier.deviceMask != 0)) }   // never cancels a hold
            } else {
                cancelIfDown()
            }
        default:
            break
        }
    }

    private func cancelIfDown() {
        guard isDown else { return }
        isDown = false
        onEvent?(.cancelled)
    }
}
