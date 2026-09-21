import Foundation
import Testing

@testable import sAiity

@Suite struct FloatRingBufferTests {
    @Test("ring buffer preserves order across wraparound")
    func preservesOrderAcrossWraparound() {
        var buffer = FloatRingBuffer(capacity: 4)
        buffer.append(contentsOf: [1, 2, 3, 4])
        buffer.dropFirst(2)
        buffer.append(contentsOf: [5, 6])

        #expect(buffer.snapshot() == [3, 4, 5, 6])
    }

    @Test("draining empties the queue and reuses its storage")
    func drainsInOrder() {
        var buffer = FloatRingBuffer(capacity: 2)
        buffer.append(contentsOf: [0.1, 0.2, 0.3])
        var output: [Float] = []
        buffer.drain(into: &output)

        #expect(output == [0.1, 0.2, 0.3])
        #expect(buffer.isEmpty)
        #expect(buffer.count == 0)
    }

    @Test("dropping all samples is safe")
    func dropsAll() {
        var buffer = FloatRingBuffer(capacity: 4)
        buffer.append(contentsOf: [1, 2])
        buffer.dropFirst(2)
        #expect(buffer.snapshot().isEmpty)
        #expect(buffer.count == 0)
    }
}
