import AppKit
import SwiftUI
import VoiceItCore

/// The small Vocabulary window, opened from the menu. Dark frosted material, like the pill. It is an ordinary window (it may take focus:
/// the person opened it on purpose), unlike the pill, which never does.
final class VocabularyWindowController: NSObject, NSWindowDelegate {
    private let model: VocabularyModel
    private var window: NSWindow?
    private var refresh: Timer?

    init(store: ConfigStore) { model = VocabularyModel(store: store) }

    func show() {
        model.reload()
        if window == nil { window = makeWindow() }
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Pick up edits made to the file by hand while the window is open.
        refresh?.invalidate()
        refresh = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self, self.model.editingID == nil else { return }
            self.model.reload()
        }
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 640),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Vocabulary"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .vibrantDark)
        w.isMovableByWindowBackground = true
        w.minSize = NSSize(width: 480, height: 520)
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        let host = NSHostingView(rootView: VocabularyView(model: model).padding(.top, 28))     // clear of the transparent title bar
        host.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: blur.leadingAnchor), host.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            host.topAnchor.constraint(equalTo: blur.topAnchor), host.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        w.contentView = blur
        w.center()
        w.delegate = self
        return w
    }

    func windowWillClose(_ notification: Notification) {
        refresh?.invalidate(); refresh = nil
        model.cancelEdit()
    }
}
