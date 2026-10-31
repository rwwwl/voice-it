import Foundation
import VoiceItDownloader

// voice-it-download --manifest <file> --to <models folder> [--only speech|cleanup]
// Downloads the models listed in the manifest into a folder, checking every file's SHA-256. This is the same code the app's setup window
// will use; it is a separate program so the app and the test harness stay free of network code.
let args = Array(CommandLine.arguments.dropFirst())
func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
guard let manifestPath = value("--manifest"), let folder = value("--to") else {
    print("usage: voice-it-download --manifest <models-manifest.json> --to <models folder> [--only speech|cleanup]"); exit(2)
}
do {
    let manifest = try ModelManifest.load(from: URL(fileURLWithPath: manifestPath))
    let models = value("--only").map { id in manifest.models.filter { $0.id == id } } ?? manifest.models
    guard !models.isEmpty else { print("nothing to download: no model called \"\(value("--only") ?? "")\""); exit(2) }
    for m in models { print("\(m.id): \(m.name), \(m.files.count) files, \(String(format: "%.0f", Double(m.totalBytes) / 1e6)) MB, licence \(m.licence)") }
    let downloader = ModelDownloader(root: URL(fileURLWithPath: folder, isDirectory: true))
    var lastPercent = -1
    let start = Date()
    try await downloader.install(models) { p in
        let percent = Int(p.fraction * 100)
        if percent != lastPercent && percent % 5 == 0 { lastPercent = percent; print(String(format: "%3d%%  %.0f of %.0f MB  %@", percent, Double(p.bytesDone) / 1e6, Double(p.bytesTotal) / 1e6, p.file)) }
    }
    print(String(format: "done in %.0f s: every file matches its checksum", Date().timeIntervalSince(start)))
    for m in models { print("\(m.id): \(ModelInstall.isComplete(m, root: URL(fileURLWithPath: folder)) ? "complete" : "INCOMPLETE")") }
} catch {
    print("failed: \(error)"); exit(1)
}
