import Testing

@testable import sAiity

struct BoundedCacheTests {
    @Test("bounded cache evicts the oldest value and supports replacement")
    func eviction() {
        var cache = BoundedCache<String, Int>(capacity: 2)
        cache["a"] = 1
        cache["b"] = 2
        cache["a"] = 3
        cache["c"] = 4

        #expect(cache["a"] == 3)
        #expect(cache["b"] == nil)
        #expect(cache["c"] == 4)
        #expect(cache.count == 2)
    }

    @Test("bounded cache clears without retaining values")
    func clear() {
        var cache = BoundedCache<String, Int>(capacity: 2)
        cache["a"] = 1
        cache.removeAll()
        #expect(cache.count == 0)
        #expect(cache["a"] == nil)
    }
}
