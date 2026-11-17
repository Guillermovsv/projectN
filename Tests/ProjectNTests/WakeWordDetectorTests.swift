import Foundation
import Testing
@testable import ProjectN

/// Synthetic “words”: a few tones in a row, varied a little in pitch and speed like repeated speech.
struct WakeWordDetectorTests {
    private struct Noise {
        var state: UInt64
        mutating func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state >> 11) % 2000) / 2000 - 0.5
        }
    }

    private func word(_ tones: [(hz: Float, seconds: Float)], pitch: Float = 1, speed: Float = 1,
                      noise: inout Noise) -> [Float] {
        var out: [Float] = []
        var phase: Float = 0
        for t in tones {
            let n = Int(t.seconds / speed * 16_000)
            for _ in 0 ..< n {
                phase += 2 * .pi * t.hz * pitch / 16_000
                out.append(0.3 * (sin(phase) + 0.5 * sin(2 * phase) + 0.25 * sin(3 * phase)) + 0.004 * noise.next())
            }
        }
        return out
    }

    private func silence(_ seconds: Float, noise: inout Noise) -> [Float] {
        (0 ..< Int(seconds * 16_000)).map { _ in 0.004 * noise.next() }
    }

    private let heyN: [(hz: Float, seconds: Float)] = [(220, 0.12), (700, 0.18), (350, 0.22)]
    private let other: [(hz: Float, seconds: Float)] = [(1800, 0.2), (150, 0.15), (2600, 0.15)]

    private func samples(_ noise: inout Noise) -> [[Float]] {
        [(1.0, 1.0), (1.03, 0.92), (0.97, 1.08)].map { p, s in
            WakeWordDetector.trimToSpeech(silence(0.3, noise: &noise) + word(heyN, pitch: p, speed: s, noise: &noise)
                                          + silence(0.3, noise: &noise))!
        }
    }

    private func detections(_ detector: WakeWordDetector, _ audio: [Float]) -> Int {
        var hits = 0
        var i = 0
        while i < audio.count {        // ~1024-sample chunks, like the mic
            if detector.feed(Array(audio[i ..< min(i + 1024, audio.count)])) != nil { hits += 1 }
            i += 1024
        }
        return hits
    }

    @Test func recognisesTheRecordedPhraseSaidAgain() throws {
        var noise = Noise(state: 1)
        let detector = try #require(WakeWordDetector(samples: samples(&noise)))
        let audio = silence(1, noise: &noise) + word(heyN, pitch: 1.01, speed: 0.95, noise: &noise)
            + word(other, noise: &noise) + silence(1, noise: &noise)
        #expect(detections(detector, audio) == 1)
    }

    @Test func ignoresOtherSoundsAndQuiet() throws {
        var noise = Noise(state: 2)
        let detector = try #require(WakeWordDetector(samples: samples(&noise)))
        let audio = silence(1, noise: &noise) + word(other, noise: &noise) + silence(0.5, noise: &noise)
            + word(other, pitch: 0.9, speed: 1.1, noise: &noise) + silence(1, noise: &noise)
        #expect(detections(detector, audio) == 0)
    }

    @Test func needsThreeRecordingsAndTrimsThemToTheSpeech() {
        var noise = Noise(state: 3)
        let all = samples(&noise)
        #expect(WakeWordDetector(samples: Array(all.prefix(2))) == nil)
        let raw = silence(0.8, noise: &noise) + word(heyN, noise: &noise) + silence(0.8, noise: &noise)
        let clip = WakeWordDetector.trimToSpeech(raw)
        #expect(clip != nil && clip!.count < raw.count - 16_000)
        #expect(WakeWordDetector.trimToSpeech(silence(2, noise: &noise)) == nil)
    }
}
