import Foundation

/// Drives the real press/release logic with the real microphone, no keyboard needed.
/// `say` plays through the speakers so the mic hears "speech"; with no text, the room stays quiet.
public enum TailSelfTest {
    public static func run(holdFor: Double, say text: String?) -> String {
        guard Permissions.microphone == .granted else {
            return "microphone not granted to this process (\(Permissions.microphone)); cannot self-test"
        }
        let controller = HoldToTalkController()
        var got: (AudioRecorder.Result, Double)?
        controller.onRecording = { r, hold, _, _, _ in got = (r, hold) }
        func pump(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        var proc: Process?
        if let text {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/say"); p.arguments = [text]
            try? p.run(); proc = p; pump(0.4)
        }
        controller.handle(.pressed(shift: false, copy: false))
        var peaks = [Float](repeating: 0, count: 16)
        let holdEnd = Date().addingTimeInterval(holdFor)
        while Date() < holdEnd {
            pump(0.03)
            for (i, v) in controller.spectrumLevels().enumerated() { peaks[i] = max(peaks[i], v) }
        }
        controller.handle(.released)
        let deadline = Date().addingTimeInterval(2)
        while got == nil && Date() < deadline { pump(0.02) }
        proc?.terminate()
        guard let (r, hold) = got else { return "no recording delivered" }
        return String(format: "held %.2f s | tail %.0f ms | audio %.2f s | voiced %.2f s | peak %.0f dBFS\nband peaks (0-100): %@",
                      hold, r.tail * 1000, r.duration, r.voicedDuration, r.peakDBFS,
                      peaks.map { String(Int($0 * 100)) }.joined(separator: " "))
    }
}
