import AppKit
import SwiftUI
import VoiceItLogic

/// The app icon the person grabs. AppKit's own dragging is used (not SwiftUI's onDrag) so it works inside a window that can be moved by its
/// background, and so the same drag also works when dropped on the real Applications folder in Finder.
struct AppIconDragSource: NSViewRepresentable {
    let image: NSImage
    let appURL: URL

    func makeNSView(context: Context) -> DragSourceView { DragSourceView(image: image, appURL: appURL) }
    func updateNSView(_ view: DragSourceView, context: Context) {}
}

final class DragSourceView: NSView, NSDraggingSource {
    private let image: NSImage
    private let appURL: URL
    private var mouseDownAt: NSPoint?
    private var dragging = false

    init(image: NSImage, appURL: URL) {
        self.image = image; self.appURL = appURL
        super.init(frame: NSRect(x: 0, y: 0, width: 108, height: 108))
        setAccessibilityLabel("Voice It. Drag onto the Applications folder")
        setAccessibilityRole(.image)
        toolTip = "Drag me onto the Applications folder"
    }
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }       // a drag here is a drag of the icon, never of the window
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) { image.draw(in: bounds.insetBy(dx: 6, dy: 6)) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) { mouseDownAt = event.locationInWindow; dragging = false }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let start = mouseDownAt else { return }
        let here = event.locationInWindow
        guard hypot(here.x - start.x, here.y - start.y) > 3 else { return }       // a few points of movement starts a drag
        dragging = true
        let item = NSDraggingItem(pasteboardWriter: appURL as NSURL)
        item.setDraggingFrame(bounds.insetBy(dx: 6, dy: 6), contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
        Log.info("setup: started dragging the app icon")
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}

/// The Applications folder the icon is dropped on.
struct FolderDropTarget: NSViewRepresentable {
    let image: NSImage
    @Binding var isTargeted: Bool
    let onDrop: () -> Void

    func makeNSView(context: Context) -> DropTargetView {
        let v = DropTargetView(image: image)
        v.onTargetChange = { t in DispatchQueue.main.async { isTargeted = t } }
        v.onDrop = onDrop
        return v
    }
    func updateNSView(_ view: DropTargetView, context: Context) { view.onDrop = onDrop }
}

final class DropTargetView: NSView {
    private let image: NSImage
    var onTargetChange: (Bool) -> Void = { _ in }
    var onDrop: () -> Void = {}
    private var targeted = false { didSet { if targeted != oldValue { needsDisplay = true; onTargetChange(targeted) } } }

    init(image: NSImage) {
        self.image = image
        super.init(frame: NSRect(x: 0, y: 0, width: 108, height: 108))
        registerForDraggedTypes([.fileURL])
        setAccessibilityLabel("Applications folder. Drop Voice It here")
        setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        if targeted {
            NSColor(red: 0.25, green: 0.5, blue: 0.98, alpha: 0.25).setFill()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14)
            path.fill()
            NSColor(red: 0.25, green: 0.5, blue: 0.98, alpha: 1).setStroke(); path.lineWidth = 2; path.stroke()
        }
        image.draw(in: bounds.insetBy(dx: 6, dy: 6))
    }

    /// Only an app counts, never some other file.
    private func appURL(from sender: NSDraggingInfo) -> URL? {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.first { $0.pathExtension == "app" }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard appURL(from: sender) != nil else { return [] }
        targeted = true
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { appURL(from: sender) != nil ? .copy : [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { targeted = false }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { appURL(from: sender) != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        targeted = false
        guard appURL(from: sender) != nil else { return false }
        Log.info("setup: the app icon was dropped on the Applications folder")
        onDrop()
        return true
    }
}

