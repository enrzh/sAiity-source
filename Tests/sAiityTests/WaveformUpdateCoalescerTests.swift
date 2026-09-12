import Foundation
import Testing

@testable import sAiity

@Suite struct WaveformUpdateCoalescerTests {
    @Test("waveform buffer keeps only the latest pending levels")
    func coalescesPendingValues() {
        var buffer = WaveformUpdateBuffer()
        buffer.submit([1])
        buffer.submit([20])

        #expect(buffer.take() == [20])
        #expect(buffer.take() == nil)
    }

    @Test("waveform buffer returns values in FIFO drain order")
    func drainsOneValueAtATime() {
        var buffer = WaveformUpdateBuffer()
        buffer.submit([0.1])
        #expect(buffer.take() == [0.1])
        buffer.submit([0.5])
        #expect(buffer.take() == [0.5])
        #expect(buffer.take() == nil)
    }
}
