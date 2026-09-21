import Foundation

/// A bounded PCM queue that never shifts the retained samples on front removal.
/// The owner supplies synchronization; this value type only owns the storage.
struct FloatRingBuffer: Sendable {
    private var storage: [Float]
    private var head = 0
    private(set) var count = 0

    init(capacity: Int = 0) {
        storage = capacity > 0 ? Array(repeating: 0, count: capacity) : []
    }

    var isEmpty: Bool { count == 0 }

    mutating func append(_ values: UnsafeBufferPointer<Float>) {
        guard !values.isEmpty else { return }
        ensureCapacity(for: count + values.count)
        let capacity = storage.count
        let tail = (head + count) % capacity
        let first = min(values.count, capacity - tail)
        for index in 0..<first { storage[tail + index] = values[index] }
        if first < values.count {
            for index in first..<values.count {
                storage[index - first] = values[index]
            }
        }
        count += values.count
    }

    mutating func append(contentsOf values: [Float]) {
        values.withUnsafeBufferPointer { append($0) }
    }

    mutating func dropFirst(_ amount: Int) {
        guard amount > 0 else { return }
        guard amount < count else {
            removeAll(keepingCapacity: true)
            return
        }
        head = (head + amount) % storage.count
        count -= amount
    }

    /// Copies the queue in order and resets it without changing capacity.
    mutating func drain(into output: inout [Float]) {
        drain(upTo: count, into: &output)
    }

    /// Copies at most `limit` samples and keeps the remainder queued. Bounded
    /// batches keep a slow model from turning one overdue call into a
    /// multi-second head-of-line block while preserving FIFO sample order.
    mutating func drain(upTo limit: Int, into output: inout [Float]) {
        output.removeAll(keepingCapacity: true)
        guard count > 0, limit > 0 else { return }
        let amount = min(count, limit)
        output.reserveCapacity(amount)
        let capacity = storage.count
        let first = min(amount, capacity - head)
        output.append(contentsOf: storage[head..<(head + first)])
        if first < amount {
            output.append(contentsOf: storage[0..<(amount - first)])
        }
        dropFirst(amount)
    }

    mutating func removeAll(keepingCapacity: Bool) {
        count = 0
        head = 0
        if !keepingCapacity { storage.removeAll(keepingCapacity: false) }
    }

    #if SAIITY_TEST_HOOKS
    func snapshot() -> [Float] {
        guard count > 0 else { return [] }
        let capacity = storage.count
        let first = min(count, capacity - head)
        return Array(storage[head..<(head + first)])
            + (first < count ? Array(storage[0..<(count - first)]) : [])
    }
    #endif

    private mutating func ensureCapacity(for required: Int) {
        guard required > storage.count else { return }
        let newCapacity = max(required, max(8, storage.count * 2))
        var replacement = Array(repeating: Float.zero, count: newCapacity)
        if count > 0 {
            let oldCapacity = storage.count
            let first = min(count, oldCapacity - head)
            for index in 0..<first { replacement[index] = storage[head + index] }
            if first < count {
                for index in first..<count { replacement[index] = storage[index - first] }
            }
        }
        storage = replacement
        head = 0
    }
}
