#if DEV_TOOLS
import AppKit
import SwiftUI
import VoiceItCore
import VoiceItDownloader

/// A developer aid: draws each setup step to a PNG without opening a window (screenshots can't capture the app's windows here),
/// so the layout can be checked. `Voice It --render-setup <folder>`.
@MainActor
func renderSetupScreens(to folder: URL) {
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let half = ModelDownloader.Progress(bytesDone: 1_480_000_000, bytesTotal: 2_743_000_000, file: "cleanup/model.safetensors")
    let screens: [(String, SetupModel)] = [
        ("1-welcome", .preview(step: .welcome)),
        ("1b-move", .preview(step: .moveToApplications, location: .other)),
        ("1b-move-opening", .preview(step: .moveToApplications, location: .other, move: .opening(URL(fileURLWithPath: "/Applications/Voice It.app"), fellBack: false))),
        ("1b-move-failed", .preview(step: .moveToApplications, location: .other, move: .failed("Voice It couldn't be copied to Applications (/Applications: You don't have permission to save the file). You can drag it there yourself in Finder."))),
        ("2-this-mac", .preview(step: .requirements, movedFrom: "/Users/you/Downloads/Voice It.app")),
        ("3-models-ready-to-download", .preview(step: .models)),
        ("3-models-downloading", .preview(step: .models, download: .running, progress: half)),
        ("3-models-failed", .preview(step: .models, download: .failed("The download stopped while fetching cleanup/model.safetensors (The Internet connection appears to be offline). Check the connection and try again: it will carry on where it stopped."))),
        ("3-models-installed", .preview(step: .models, edit: { $0.speechInstalled = true; $0.cleanupInstalled = true }, wantsCleanup: true)),
                ("5-permissions-none", .preview(step: .permissions)),
        ("5-permissions-some", .preview(step: .permissions, edit: { $0.microphoneGranted = true; $0.inputMonitoringGranted = true })),
        ("5-permissions-preparing", .preview(step: .permissions, edit: { $0.speechInstalled = true; $0.microphoneGranted = true }, speech: .loading)),
        ("6-try-it", .preview(step: .tryIt, edit: { $0.speechInstalled = true }, speech: .ready(seconds: 33))),
        ("7-menu-bar", .preview(step: .menuBar, edit: { $0.speechInstalled = true }, speech: .loading)),
        ("6-try-it-failed", .preview(step: .tryIt, edit: { $0.speechInstalled = true }, speech: .failed("the model files could not be read"))),
    ]
    for (name, model) in screens {
        let view = SetupView(model: model, scrolls: false).padding(.top, 28).background(Color(red: 0.12, green: 0.12, blue: 0.13)).environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { print("could not draw \(name)"); continue }
        try? png.write(to: folder.appendingPathComponent("\(name).png"))
        print("drew \(name)")
    }
}
#endif
