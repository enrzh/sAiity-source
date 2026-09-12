import Foundation

struct WaveformUpdateBuffer: Sendable {
    private(set) var latest: [Float]?

    mutating func submit(_ values: [Float]) {
        latest = values
    }

    mutating func take() -> [Float]? {
        defer { latest = nil }
        return latest
    }
}

/// Keeps audio callbacks from queueing one main-actor task per buffer.
/// The UI only needs the newest level set once per display interval.
final class WaveformUpdateCoalescer: @unchecked Sendable {
    typealias Delivery = @MainActor @Sendable ([Float]) -> Void

    private let lock = NSLock()
    private let interval: Duration
    private let deliver: Delivery
    private var buffer = WaveformUpdateBuffer()
    private var scheduled = false

    init(interval: Duration = .milliseconds(16), deliver: @escaping Delivery) {
        self.interval = interval
        self.deliver = deliver
    }

    func submit(_ values: [Float]) {
        let shouldStart = lock.withLock {
            buffer.submit(values)
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        guard shouldStart else { return }
        Task { @MainActor [weak self] in
            await self?.drain()
        }
    }

    @MainActor
    private func drain() async {
        while !Task.isCancelled {
            guard let values = takeLatestOrFinish() else { return }
            deliver(values)
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
        }
    }

    private func takeLatestOrFinish() -> [Float]? {
        lock.withLock {
            guard let values = buffer.take() else {
                scheduled = false
                return nil
            }
            return values
        }
    }
}
