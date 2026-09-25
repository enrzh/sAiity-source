import Foundation

/// Small LRU cache for hot-path derived results. A caption session can run for
/// hours, so an unbounded dictionary would turn every distinct subtitle into a
/// retained translation even after it has left the screen.
struct BoundedCache<Key: Hashable, Value> {
    let capacity: Int
    private var values: [Key: Value] = [:]
    private var order: [Key] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var count: Int { values.count }

    subscript(key: Key) -> Value? {
        get { values[key] }
        set {
            guard let newValue else {
                values.removeValue(forKey: key)
                order.removeAll { $0 == key }
                return
            }
            order.removeAll { $0 == key }
            order.append(key)
            values[key] = newValue
            while order.count > capacity {
                values.removeValue(forKey: order.removeFirst())
            }
        }
    }

    mutating func removeAll(keepingCapacity: Bool = true) {
        values.removeAll(keepingCapacity: keepingCapacity)
        order.removeAll(keepingCapacity: keepingCapacity)
    }
}
