import Accelerate
import Foundation

/// Something that listens to 16 kHz mono audio and says when it heard the wake phrase.
protocol WakeDetecting: AnyObject {
    /// Returns the match distance when these samples complete something that sounds like “Hey N”.
    func feed(_ samples: [Float]) -> Float?
}

/// A light “Hey N” spotter tuned to your voice: compares the sound (MFCC features, dynamic time warping) with
/// a few recordings of you saying it. It never turns audio into text; only a match wakes the speech recognizer,
/// which then confirms it. Not thread-safe: feed it from one queue.
final class WakeWordDetector: WakeDetecting {
    static let sampleRate = 16_000
    static let frameLength = 400        // 25 ms
    static let hop = 160                // 10 ms
    private static let fftSize = 512
    private static let melBands = 26
    private static let coefficients = 12   // c1…c12 (c0 is loudness, which says nothing about the word)
    /// A frame counts as voice this far (natural log of power) above the background noise: 10 dB.
    private static let voiceMargin: Float = 2.3

    enum Sensitivity: String, CaseIterable, Identifiable {
        case low, normal, high
        var id: String { rawValue }
        var factor: Float {
            switch self {
            case .low: return 1.15
            case .normal: return 1.4
            case .high: return 1.7
            }
        }
    }

    private let templates: [[[Float]]]
    let threshold: Float
    private let maxFrames: Int
    private var pending: [Float] = []
    private var frames: [[Float]] = []
    private var energies: [Float] = []
    private var noiseFloor: Float?
    private var sinceCheck = 0
    private var quietFrames = 0

    /// nil with fewer than 3 usable samples.
    init?(samples: [[Float]], sensitivity: Sensitivity = .normal) {
        let feats = samples.map { Self.normalized(Self.features(of: $0).mfcc) }.filter { $0.count >= 15 }
        guard feats.count >= 3 else { return nil }
        templates = feats
        var pairs: [Float] = []
        for i in feats.indices { for j in feats.indices where j > i { pairs.append(Self.dtw(feats[i], feats[j])) } }
        threshold = pairs.reduce(0, +) / Float(pairs.count) * sensitivity.factor
        maxFrames = Int(Float(feats.map(\.count).max()!) * 1.25) + 2
    }

    func feed(_ samples: [Float]) -> Float? {
        pending += samples
        var hit: Float?
        var offset = 0
        while pending.count - offset >= Self.frameLength {
            let (mfcc, energy) = Self.frame(Array(pending[offset ..< offset + Self.frameLength]))
            offset += Self.hop
            frames.append(mfcc); energies.append(energy)
            if frames.count > maxFrames { frames.removeFirst(); energies.removeFirst() }
            // Background noise: follows quiet sound at once, louder sound only slowly.
            if let floor = noiseFloor { noiseFloor = energy < floor ? energy : floor + 0.002 * (energy - floor) }
            else { noiseFloor = energy }
            quietFrames = max(0, quietFrames - 1)
            sinceCheck += 1
            if sinceCheck >= 5, quietFrames == 0, hit == nil {   // every 50 ms
                sinceCheck = 0
                if let d = check() { hit = d; quietFrames = 150 }  // don't fire again for 1.5 s
            }
        }
        pending.removeFirst(offset)
        return hit
    }

    /// The best match of the latest audio against every recording, at a few speaking speeds.
    private func check() -> Float? {
        guard let floor = noiseFloor else { return nil }
        var best = Float.infinity
        for t in templates {
            for scale in [0.8, 1.0, 1.2] as [Float] {
                let n = Int(Float(t.count) * scale)
                guard n >= 10, n <= frames.count else { continue }
                let e = energies.suffix(n)
                // Mostly silence or steady noise isn't speech; skip the work.
                guard Float(e.filter { $0 > floor + Self.voiceMargin }.count) >= Float(n) * 0.35 else { continue }
                best = min(best, Self.dtw(Self.normalized(Array(frames.suffix(n))), t))
            }
        }
        return best < threshold ? best : nil
    }

    // MARK: Enrollment

    /// Cuts a recording down to the speech in it (with a little margin). nil if no clear speech was heard or it
    /// is too short or too long to be “Hey N”.
    static func trimToSpeech(_ samples: [Float]) -> [Float]? {
        let energies = features(of: samples).energy
        guard energies.count > 20 else { return nil }
        let sorted = energies.sorted()
        let floor = sorted[sorted.count / 10], peak = sorted[sorted.count - 1]
        guard peak - floor > voiceMargin * 1.5 else { return nil }
        let level = max(floor + voiceMargin, peak - 3 * voiceMargin)
        guard let first = energies.firstIndex(where: { $0 > level }),
              let last = energies.lastIndex(where: { $0 > level }) else { return nil }
        let seconds = Double(last - first) * Double(hop) / Double(sampleRate)
        guard seconds >= 0.25, seconds <= 1.8 else { return nil }
        let start = max(0, (first - 10) * hop)
        let end = min(samples.count, (last + 10) * hop + frameLength)
        return Array(samples[start ..< end])
    }

    // MARK: Features

    static func features(of samples: [Float]) -> (mfcc: [[Float]], energy: [Float]) {
        var mfcc: [[Float]] = [], energy: [Float] = []
        var i = 0
        while i + frameLength <= samples.count {
            let (m, e) = frame(Array(samples[i ..< i + frameLength]))
            mfcc.append(m); energy.append(e)
            i += hop
        }
        return (mfcc, energy)
    }

    private static let window = vDSP.window(ofType: Float.self, usingSequence: .hamming, count: frameLength, isHalfWindow: false)
    private static let dft = try! vDSP.DiscreteFourierTransform(count: fftSize, direction: .forward,
                                                               transformType: .complexComplex, ofType: Float.self)
    private static let melFilters: [[Float]] = {
        func mel(_ hz: Float) -> Float { 2595 * log10(1 + hz / 700) }
        func hz(_ mel: Float) -> Float { 700 * (pow(10, mel / 2595) - 1) }
        let bins = fftSize / 2 + 1
        let lo = mel(60), hi = mel(Float(sampleRate) / 2)
        let edges = (0 ... melBands + 1).map { hz(lo + (hi - lo) * Float($0) / Float(melBands + 1)) * Float(fftSize) / Float(sampleRate) }
        return (0 ..< melBands).map { b in
            (0 ..< bins).map { k in
                let f = Float(k)
                if f <= edges[b] || f >= edges[b + 2] { return 0 }
                return f <= edges[b + 1] ? (f - edges[b]) / (edges[b + 1] - edges[b]) : (edges[b + 2] - f) / (edges[b + 2] - edges[b + 1])
            }
        }
    }()
    private static let dct: [[Float]] = (1 ... coefficients).map { c in
        (0 ..< melBands).map { m in cos(Float.pi * Float(c) * (Float(m) + 0.5) / Float(melBands)) }
    }

    /// One 25 ms frame: 12 MFCCs and its log energy.
    private static func frame(_ x: [Float]) -> ([Float], Float) {
        var s = x
        for i in stride(from: s.count - 1, to: 0, by: -1) { s[i] -= 0.97 * s[i - 1] }   // pre-emphasis
        let energy = log(max(vDSP.sumOfSquares(s), 1e-10))
        s = vDSP.multiply(s, window)
        let real = s + [Float](repeating: 0, count: fftSize - s.count)
        let (re, im) = dft.transform(real: real, imaginary: [Float](repeating: 0, count: fftSize))
        let bins = fftSize / 2 + 1
        let power = vDSP.add(vDSP.square(Array(re[0 ..< bins])), vDSP.square(Array(im[0 ..< bins])))
        let logMel = melFilters.map { log(max(vDSP.dot($0, power), 1e-10)) }
        return (dct.map { vDSP.dot($0, logMel) }, energy)
    }

    /// Removes the average of each coefficient: the same word through a different mic or room still matches.
    static func normalized(_ frames: [[Float]]) -> [[Float]] {
        guard let width = frames.first?.count else { return frames }
        var mean = [Float](repeating: 0, count: width)
        for f in frames { mean = vDSP.add(mean, f) }
        mean = vDSP.divide(mean, Float(frames.count))
        return frames.map { vDSP.subtract($0, mean) }
    }

    /// Dynamic time warping distance (symmetric steps), normalised by length so short and long words compare.
    static func dtw(_ a: [[Float]], _ b: [[Float]]) -> Float {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return .infinity }
        var prev = [Float](repeating: .infinity, count: m + 1)
        var cur = prev
        prev[0] = 0
        for i in 1 ... n {
            cur[0] = .infinity
            for j in 1 ... m {
                let d = sqrt(vDSP.distanceSquared(a[i - 1], b[j - 1]))
                cur[j] = min(prev[j - 1] + 2 * d, prev[j] + d, cur[j - 1] + d)
            }
            swap(&prev, &cur)
        }
        return prev[m] / Float(n + m)
    }
}

/// Your recordings of “Hey N” (16 kHz mono), kept in the ProjectN home. Only these short clips are stored.
enum WakeWordSamples {
    static var file: URL { AppHome.root.appendingPathComponent("hey-n-samples.json") }

    static func load() -> [[Float]] {
        guard let data = try? Data(contentsOf: file),
              let clips = try? JSONDecoder().decode([Data].self, from: data) else { return [] }
        return clips.map { d in d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } }
    }

    static func save(_ samples: [[Float]]) {
        if samples.isEmpty { try? FileManager.default.removeItem(at: file); return }
        let clips = samples.map { s in s.withUnsafeBufferPointer { Data(buffer: $0) } }
        if let data = try? JSONEncoder().encode(clips) { try? data.write(to: file, options: .atomic) }
    }
}
