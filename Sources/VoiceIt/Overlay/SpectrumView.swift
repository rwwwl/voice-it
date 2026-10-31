import SwiftUI

/// 16 bars that rise fast and fall slowly, driven by live mic bands.
final class SpectrumModel {
    static let bars = 16
    private(set) var heights = [Double](repeating: 3, count: SpectrumModel.bars)
    private(set) var glow = 0.0
    private var smooth = 0.0
    private var lastTime: TimeInterval = 0
    var levels: () -> [Float] = { [Float](repeating: 0, count: SpectrumModel.bars) }

    func reset() { heights = [Double](repeating: 3, count: Self.bars); glow = 0; smooth = 0; lastTime = 0 }

    /// Advance to `now`. Rise 35% and fall 12% of the way to target per frame at 60 fps.
    func step(now: TimeInterval, reduceMotion: Bool) {
        if reduceMotion {
            // Static pattern, no animation.
            for i in 0..<Self.bars { heights[i] = 3 + 23 * min(1, 0.1 + 0.45 * exp(-Double(i) / 4.5) + 0.3 * exp(-pow((Double(i) - 6) / 1.5, 2))) * 0.6 }
            glow = 0.25
            return
        }
        let dt = lastTime == 0 ? 1.0 / 60 : min(now - lastTime, 0.1)
        guard dt > 0 else { return }
        lastTime = now
        let frames = dt * 60
        let target = levels()
        var sum = 0.0
        for i in 0..<Self.bars {
            let t = 3 + Double(i < target.count ? target[i] : 0) * 23
            let rate = t > heights[i] ? 0.35 : 0.12
            heights[i] += (t - heights[i]) * (1 - pow(1 - rate, frames))
            sum += heights[i]
        }
        let avg = (sum / Double(Self.bars) - 3) / 17
        smooth += (avg - smooth) * (1 - pow(0.85, frames))
        glow = max(0, min(1, smooth * 1.8))
    }
}

struct SpectrumCanvas: View {
    let model: SpectrumModel
    var body: some View {
        // The canvas must read the timeline date itself, otherwise SwiftUI sees an unchanged view and never redraws it.
        TimelineView(.animation) { tl in
            Canvas { ctx, size in
                _ = tl.date
                ctx.addFilter(.shadow(color: Color(red: 1, green: 0.59, blue: 0.39).opacity(0.7), radius: 8))
                let gradient = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: [Color(red: 1, green: 0.83, blue: 0.48), Color(red: 1, green: 0.54, blue: 0.36), Color(red: 1, green: 0.37, blue: 0.62)]),
                    startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: size.width, y: 0))
                for i in 0..<SpectrumModel.bars {
                    let h = CGFloat(model.heights[i])
                    let rect = CGRect(x: CGFloat(i * 7), y: size.height / 2 - h / 2, width: 4, height: h)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: gradient)
                }
            }
        }
        .frame(width: PillMetrics.spectrumWidth, height: PillMetrics.spectrumHeight)
    }
}
