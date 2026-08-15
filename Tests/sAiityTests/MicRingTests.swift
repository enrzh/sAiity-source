import Foundation
import Testing

@testable import sAiity

/// The ring is the seam between two clocks — Core Audio's mic thread and
/// ScreenCaptureKit's capture queue — and every failure mode here is silent:
/// an underrun that blocked would stall captions, an overflow kept forever
/// would drift the mic seconds behind the audio it accompanies, and an
/// unclamped sum folds two loud sources into noise.
struct MicRingTests {

    @Test("A stale microphone-on request is rejected after the setting turns off")
    func staleMicRequestDoesNotReopenInput() {
        #expect(!MicMix.shouldStart(requested: true, current: false))
        #expect(MicMix.shouldStart(requested: true, current: true))
    }

    @Test("Underrun mixes what exists and leaves the rest untouched")
    func underrunIsPartial() {
        var ring = MicRing()
        ring.push([0.5, 0.5])
        var dst: [Float] = [0.1, 0.1, 0.1, 0.1]
        dst.withUnsafeMutableBufferPointer { ring.mix(into: $0.baseAddress!, count: 4) }
        #expect(abs(dst[0] - 0.6) < 1e-6)
        #expect(abs(dst[1] - 0.6) < 1e-6)
        // The mic had nothing for these — system audio passes through alone.
        #expect(abs(dst[2] - 0.1) < 1e-6)
        #expect(abs(dst[3] - 0.1) < 1e-6)
        #expect(ring.samples.isEmpty, "mixed samples must be consumed")
    }

    @Test("Overflow drops the OLDEST samples so the mix stays near-live")
    func overflowDropsOldest() {
        var ring = MicRing(capacity: 4)
        ring.push([1, 2, 3, 4])
        ring.push([5, 6])
        #expect(ring.samples == [3, 4, 5, 6])
    }

    @Test("Two full-scale sources clamp instead of folding over")
    func sumIsClamped() {
        var ring = MicRing()
        ring.push([0.8, -0.9])
        var dst: [Float] = [0.7, -0.6]
        dst.withUnsafeMutableBufferPointer { ring.mix(into: $0.baseAddress!, count: 2) }
        #expect(dst[0] == 1.0)
        #expect(dst[1] == -1.0)
    }

    @Test("Consecutive mixes drain in arrival order")
    func drainsInOrder() {
        var ring = MicRing()
        ring.push([0.1, 0.2, 0.3])
        var a: [Float] = [0, 0]
        a.withUnsafeMutableBufferPointer { ring.mix(into: $0.baseAddress!, count: 2) }
        var b: [Float] = [0]
        b.withUnsafeMutableBufferPointer { ring.mix(into: $0.baseAddress!, count: 1) }
        #expect(abs(a[0] - 0.1) < 1e-6 && abs(a[1] - 0.2) < 1e-6)
        #expect(abs(b[0] - 0.3) < 1e-6)
    }
}
