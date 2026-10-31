import AppKit
import Carbon.HIToolbox
import Foundation

/// Puts text in the focused app with a simulated Cmd-V, keeping the user's clipboard intact.
public enum Paster {
    private typealias SavedItem = [(type: NSPasteboard.PasteboardType, data: Data)]

    public static var secureInputActive: Bool { IsSecureEventInputEnabled() }

    /// Replaces the clipboard with `text`, sends Cmd-V, then restores every type that was on the clipboard.
    /// Returns the uptime at which Cmd-V was posted (the end of the latency clock).
    @MainActor
    public static func paste(_ text: String) async -> TimeInterval {
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        write(text, to: pb)
        let ours = pb.changeCount
        sendCommandV()
        let posted = ProcessInfo.processInfo.systemUptime
        try? await Task.sleep(nanoseconds: UInt64(Defaults.clipboardRestoreDelay * 1_000_000_000))
        // If something else wrote to the clipboard meanwhile (the user copied), leave theirs alone.
        if pb.changeCount == ours { restore(saved, to: pb) }
        return posted
    }

    /// Leaves `text` on the clipboard without pasting (used when pasting would be wrong or impossible).
    /// `transient: false` is for a copy the user asked for, which a clipboard manager may keep.
    @MainActor
    public static func copyOnly(_ text: String, transient: Bool = true) {
        write(text, to: NSPasteboard.general, transient: transient)
    }

    private static func write(_ text: String, to pb: NSPasteboard, transient: Bool = true) {
        pb.clearContents()
        pb.setString(text, forType: .string)
        // Asks clipboard managers to ignore this temporary entry.
        if transient { pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) }
    }

    private static func snapshot(_ pb: NSPasteboard) -> [SavedItem] {
        (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    private static func restore(_ saved: [SavedItem], to pb: NSPasteboard) {
        pb.clearContents()
        guard !saved.isEmpty else { return }
        let items = saved.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        pb.writeObjects(items)
    }

    private static func sendCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}
