import SwiftUI

/// "Cleaning up" with a light sweep; letters scramble, resolve left to right, hold, then scramble out (3.2 s loop).
final class ScrambleModel {
    static let word = Array("Cleaning up")
    private static let alphabet = Array("abcdefghijklnopqrstuvxyz")   // no m or w, which would widen the pill
    private var scrambled = ScrambleModel.word
    private var lastTick = -1

    func text(at elapsed: TimeInterval) -> String {
        let t = elapsed.truncatingRemainder(dividingBy: 3.2) * 1000
        let tick = Int(t / 60)
        let word = Self.word
        if tick != lastTick {
            lastTick = tick
            scrambled = word.map { $0 == " " ? " " : Self.alphabet.randomElement()! }
        }
        let n = word.count
        let out: [Character]
        if t < 500 { out = scrambled }
        else if t < 1100 { let k = Int((t - 500) / 600 * Double(n)); out = Array(word[..<k]) + Array(scrambled[k...]) }
        else if t < 2500 { out = word }
        else { let k = Int((t - 2500) / 700 * Double(n)); out = Array(scrambled[..<k]) + Array(word[k...]) }
        return String(out)
    }
}

/// The bright band that travels across the text every 1.8 s.
func sweepStyle(elapsed: TimeInterval) -> LinearGradient {
    let centre = -0.3 + 1.6 * (elapsed / 1.8).truncatingRemainder(dividingBy: 1)
    let locs = [centre - 0.35, centre, centre + 0.35].map { min(1, max(0, $0)) }
    return LinearGradient(stops: [
        .init(color: .white.opacity(0.45), location: 0),
        .init(color: .white.opacity(0.45), location: locs[0]),
        .init(color: .white, location: locs[1]),
        .init(color: .white.opacity(0.45), location: locs[2]),
        .init(color: .white.opacity(0.45), location: 1),
    ], startPoint: .leading, endPoint: .trailing)
}

/// "Loading model": the sweep without the letter scramble.
struct LoadingLabel: View {
    let reduceMotion: Bool
    @State private var start = Date()
    var body: some View {
        if reduceMotion {
            Text("Loading model").font(PillMetrics.font).foregroundStyle(.white)
        } else {
            TimelineView(.animation) { tl in
                Text("Loading model").font(PillMetrics.font).foregroundStyle(sweepStyle(elapsed: tl.date.timeIntervalSince(start)))
            }
        }
    }
}

/// A thin warm line travelling along the bottom edge while a model loads.
struct LoadingBar: View {
    let reduceMotion: Bool
    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { tl in
                let t = reduceMotion ? 0.5 : (tl.date.timeIntervalSinceReferenceDate / 1.4).truncatingRemainder(dividingBy: 1)
                // ease in and out, from off the left edge to off the right edge
                let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
                let w = geo.size.width * 0.4
                LinearGradient(colors: [.clear, Color(red: 1, green: 0.70, blue: 0.48), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: w, height: 2)
                    .offset(x: -w + (geo.size.width + w) * eased, y: geo.size.height - 2)
            }
        }
    }
}

struct ProcessingLabel: View {
    let reduceMotion: Bool
    @State private var start = Date()
    @State private var model = ScrambleModel()

    var body: some View {
        if reduceMotion {
            Text(String(ScrambleModel.word)).font(PillMetrics.font).foregroundStyle(.white).frame(width: 92)
        } else {
            TimelineView(.animation) { tl in
                let elapsed = tl.date.timeIntervalSince(start)
                // A bright band travelling across the text every 1.8 s.
                let centre = -0.3 + 1.6 * (elapsed / 1.8).truncatingRemainder(dividingBy: 1)
                let locs = [centre - 0.35, centre, centre + 0.35].map { min(1, max(0, $0)) }
                Text(model.text(at: elapsed))
                    .font(PillMetrics.font)
                    .foregroundStyle(LinearGradient(stops: [
                        .init(color: .white.opacity(0.45), location: 0),
                        .init(color: .white.opacity(0.45), location: locs[0]),
                        .init(color: .white, location: locs[1]),
                        .init(color: .white.opacity(0.45), location: locs[2]),
                        .init(color: .white.opacity(0.45), location: 1),
                    ], startPoint: .leading, endPoint: .trailing))
                    .frame(width: 92)
            }
        }
    }
}
