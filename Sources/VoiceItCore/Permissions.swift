import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics

public enum Permissions {
    public enum Status { case granted, denied, notDetermined }

    public static var microphone: Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    public static func requestMicrophone(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
    }

    /// Input Monitoring, needed for the global hold-to-talk key.
    public static var inputMonitoring: Bool { CGPreflightListenEventAccess() }

    @discardableResult
    public static func requestInputMonitoring() -> Bool { CGRequestListenEventAccess() }

    /// Accessibility, needed to send the simulated Cmd-V.
    public static var accessibility: Bool { AXIsProcessTrusted() }

    @discardableResult
    public static func requestAccessibility() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    public static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    public static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    public static func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
