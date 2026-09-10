import Foundation
import Testing

@testable import sAiity

@Suite(.serialized)
struct WhisperModelCacheTests {
    @Test("resident models are reused and evicted after the idle window")
    func reuseAndIdleEviction() async throws {
        let loads = Counter()
        let unloads = Counter()
        let cache = WhisperModelCache<String, FakeResource>(idleDuration: .milliseconds(20)) { key in
            await loads.increment()
            return FakeResource(id: key, unloads: unloads)
        }

        let first = try await cache.withModel(for: "base") { resource in
            resource.id
        }
        let second = try await cache.withModel(for: "base") { resource in
            resource.id
        }
        #expect(first == "base")
        #expect(second == "base")
        #expect(await loads.value == 1)
        #expect(await unloads.value == 0)

        for _ in 0..<100 where await cache.residentCountForTests > 0 {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await cache.residentCountForTests == 0)
        #expect(await unloads.value == 1)
    }

    @Test("invalidating a resident model unloads it before the next load")
    func invalidation() async throws {
        let loads = Counter()
        let unloads = Counter()
        let cache = WhisperModelCache<String, FakeResource>(idleDuration: .seconds(1)) { key in
            await loads.increment()
            return FakeResource(id: key, unloads: unloads)
        }

        _ = try await cache.withModel(for: "small") { resource in resource.id }
        await cache.invalidate("small")
        #expect(await cache.residentCountForTests == 0)
        #expect(await unloads.value == 1)

        _ = try await cache.withModel(for: "small") { resource in resource.id }
        #expect(await loads.value == 2)
    }

    private final class FakeResource: WhisperModelResource, @unchecked Sendable {
        let id: String
        let unloads: Counter

        init(id: String, unloads: Counter) {
            self.id = id
            self.unloads = unloads
        }

        func unload() async {
            await unloads.increment()
        }
    }

    private actor Counter {
        private(set) var value = 0

        func increment() {
            value += 1
        }
    }
}
