import Accelerate
import Foundation

/// 16 log-spaced frequency bands (about 100 Hz to 6.4 kHz) from the 16 kHz capture stream, each scaled 0...1.
/// Not thread-safe by itself; AudioRecorder calls it under its lock.
final class SpectrumAnalyzer {
    static let bandCount = 16
    private let n = 512
    private let log2n: vDSP_Length = 9
    private let setup: FFTSetup
    private var window: [Float]
    private var ring: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var mags: [Float]
    private let bandBins: [Range<Int>]
    private(set) var levels = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)

    /// dB (relative to full scale, per FFT bin) that maps to an empty and a full bar. Tuned by eye with `say` and a real voice.
    private let floorDB: Float = -64
    private let ceilDB: Float = -30
    /// Speech has far less energy at high frequencies, so lift higher bands a little.
    private let tiltDBPerBand: Float = 1.0

    init() {
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        ring = [Float](repeating: 0, count: n)
        windowed = [Float](repeating: 0, count: n)
        real = [Float](repeating: 0, count: n / 2)
        imag = [Float](repeating: 0, count: n / 2)
        mags = [Float](repeating: 0, count: n / 2)
        let binHz = Float(Defaults.sampleRate) / Float(n)
        bandBins = (0..<SpectrumAnalyzer.bandCount).map { i in
            let lo = 100 * pow(64, Float(i) / 16), hi = 100 * pow(64, Float(i + 1) / 16)
            let first = max(1, Int(lo / binHz))
            return first..<max(first + 1, Int((hi / binHz).rounded(.up)))
        }
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func reset() {
        ring = [Float](repeating: 0, count: n)
        levels = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    }

    func push(_ samples: UnsafePointer<Int16>, count: Int) {
        let take = min(count, n)
        ring.removeFirst(take)
        for i in (count - take)..<count { ring.append(Float(samples[i]) / 32768) }
        analyze()
    }

    private func analyze() {
        vDSP_vmul(ring, 1, window, 1, &windowed, 1, vDSP_Length(n))
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n / 2))
            }
        }
        for (i, bins) in bandBins.enumerated() {
            var peak: Float = 0
            for b in bins { peak = max(peak, mags[b]) }
            let amplitude = peak.squareRoot() / Float(n)          // about the peak amplitude of a sine in this bin
            let db = 20 * log10(max(amplitude, 1e-9)) + tiltDBPerBand * Float(i)
            // The power curve flattens faint room noise so the bars sit still when the mic hears nothing.
            levels[i] = pow(min(1, max(0, (db - floorDB) / (ceilDB - floorDB))), 1.6)
        }
    }
}
