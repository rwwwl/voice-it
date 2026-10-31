import AppKit
import SwiftUI
import VoiceItCore

/// The setup window: a plain window (it may take focus, the person opened it) with the same dark frosted look as the Vocabulary window.
/// Opened by itself on a first launch or when a model is missing, and from the menu ("Set up again…", "Install cleanup model…").
@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    private let services: SetupModel.Services
    private var window: NSWindow?
    private var model: SetupModel?
    private var timer: Timer?

    init(services: SetupModel.Services) { self.services = services }

    var isOpen: Bool { window?.isVisible == true }

    /// `startAt` nil: the welcome page. `wantsCleanup`: pre-tick the cleanup model (the "Install cleanup model…" menu row).
    func show(startAt: SetupStep? = nil, wantsCleanup: Bool? = nil, movedFrom: String? = nil) {
        model?.cancelDownload()
        let m = SetupModel(services: services, startAt: startAt ?? .welcome, wantsCleanup: wantsCleanup, movedFrom: movedFrom)
        m.recheck()
        model = m
        let w = window ?? makeWindow()
        window = w
        w.contentView = makeContent(for: m)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.model?.refresh() } }
    }

    #if DEV_TOOLS
    /// A developer aid (`--setup-auto`): press Download without a click, so a fresh install can be run end to end unattended.
    /// A developer aid (`--selftest-drag`): performs a real mouse drag (synthesised system events, so the real cursor moves for a couple of
    /// seconds) from the app icon to the Applications folder in the window, to prove the drag works end to end.
    func debugDrag() {
        func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
            guard let view else { return nil }
            if let v = view as? T { return v }
            for sub in view.subviews { if let v = find(type, in: sub) { return v } }
            return nil
        }
        model?.step = .moveToApplications
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let w = self.window, let source = find(DragSourceView.self, in: w.contentView), let target = find(DropTargetView.self, in: w.contentView) else {
                Log.info("drag self-test: the icon or the folder was not found in the window"); exit(1)
            }
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            func screenPoint(_ v: NSView) -> CGPoint {
                let inWindow = v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
                let ns = w.convertPoint(toScreen: inWindow)
                return CGPoint(x: ns.x, y: primaryHeight - ns.y)
            }
            let from = screenPoint(source), to = screenPoint(target)
            Log.info("drag self-test: dragging from \(Int(from.x)),\(Int(from.y)) to \(Int(to.x)),\(Int(to.y))")
            DispatchQueue.global().async {
                func post(_ type: CGEventType, _ p: CGPoint) {
                    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
                }
                post(.mouseMoved, from); usleep(300_000)
                post(.leftMouseDown, from); usleep(150_000)
                for i in 1...30 {
                    let t = Double(i) / 30
                    post(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)); usleep(25_000)
                }
                for _ in 0..<5 { post(.leftMouseDragged, to); usleep(40_000) }
                usleep(200_000)
                post(.leftMouseUp, to)
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { Log.info("drag self-test: finished without the drop being received"); exit(1) }
            }
        }
    }

    func debugMove() { model?.step = .moveToApplications; model?.moveToApplications() }
    func debugStartDownload() { model?.step = .models; model?.startDownload() }

    /// A developer aid (`--selftest-paste`): puts the cursor in the practice box and sends the same Cmd-V the app sends after a dictation,
    /// then logs what the box holds. Proves a paste can land in the app's own window.
    func debugPasteTest() {
        func textView(in view: NSView?) -> NSTextView? {
            guard let view else { return nil }
            if let tv = view as? NSTextView { return tv }
            for sub in view.subviews { if let tv = textView(in: sub) { return tv } }
            return nil
        }
        model?.step = .tryIt
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, let w = self.window, let tv = textView(in: w.contentView) else { Log.info("paste self-test: no practice box found"); exit(1) }
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            w.makeFirstResponder(tv)
            Task { @MainActor in
                _ = await Paster.paste("self-test words")
                try? await Task.sleep(nanoseconds: 800_000_000)
                Log.info("paste self-test: the practice box holds \"\(tv.string)\"; frontmost app is \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")")
                try? await Task.sleep(nanoseconds: 500_000_000)      // the log is written in the background: let the line reach the file
                exit(tv.string.contains("self-test words") ? 0 : 1)
            }
        }
    }
    #endif

    private func makeContent(for m: SetupModel) -> NSView {
        let blur = NSVisualEffectView()
        blur.material = .hudWindow; blur.blendingMode = .behindWindow; blur.state = .active
        let host = NSHostingView(rootView: SetupView(model: m, onDone: { [weak self] in self?.window?.close() }).padding(.top, 28))
        host.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: blur.leadingAnchor), host.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            host.topAnchor.constraint(equalTo: blur.topAnchor), host.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        return blur
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 608), styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Set up Voice It"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .vibrantDark)
        w.isMovableByWindowBackground = true
        w.center()
        w.delegate = self
        return w
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            timer?.invalidate(); timer = nil
            model?.cancelDownload()
        }
    }
}
