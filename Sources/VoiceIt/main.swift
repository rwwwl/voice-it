import AppKit

import VoiceItCore

#if DEV_TOOLS   // hidden test modes, left out of the shared build
// Hidden test mode: `open -n -W --stdout out.txt "build/Voice It.app" --args --selftest-tail <hold> ["say text"]`
if let i = CommandLine.arguments.firstIndex(of: "--selftest-tail") {
    let args = Array(CommandLine.arguments.dropFirst(i + 1))
    print(TailSelfTest.run(holdFor: Double(args.first ?? "1.5") ?? 1.5, say: args.count > 1 ? args[1] : nil))
    exit(0)
}

// Hidden test mode: `open -n -W --stdout out.txt "build/Voice It.app" --args --selftest-cleanup "um some text"`
// Runs the cleanup model inside the signed app bundle, to prove its Metal shaders and model files are found.
if let i = CommandLine.arguments.firstIndex(of: "--selftest-cleanup") {
    let text = CommandLine.arguments.dropFirst(i + 1).first ?? "um so this is a test of the the cleanup model"
    let config = ConfigStore().current()
    let cleaner = MLXCleaner(modelDirectory: config.cleanupModelDirectory)
    Task {
        do {
            try await cleaner.load()
            let t0 = ProcessInfo.processInfo.systemUptime
            let first = try await cleaner.clean(text, style: .natural, terms: config.dictionary.map(\.term))
            let t1 = ProcessInfo.processInfo.systemUptime
            let second = try await cleaner.clean(text, style: .natural, terms: config.dictionary.map(\.term))
            print("first:  \(first.text)   (\(Int((t1 - t0) * 1000)) ms, includes building the prompt cache)")
            print("second: \(second.text)   (\(Int(second.totalSeconds * 1000)) ms, prompt tokens read \(second.promptTokensRead) of \(second.promptTokens))")
        } catch { print("FAILED: \(error)") }
        exit(0)
    }
    RunLoop.main.run()
}

#endif

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
app.run()
