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

    /// Removal is synchronous and unloading is not, so `forget` is the hook
    /// that lets a file be deleted without leaving a resident model mapped over
    /// it. The unload still has to happen — and an idle model has to leave the
    /// cache immediately, or the next dictation picks up a model whose bytes
    /// are gone.
    @Test("forgetting a resident model drops it and unloads it")
    func forgettingDropsAndUnloads() async throws {
        let loads = Counter()
        let unloads = Counter()
        let cache = WhisperModelCache<String, FakeResource>(idleDuration: .seconds(60)) { key in
            await loads.increment()
            return FakeResource(id: key, unloads: unloads)
        }

        _ = try await cache.withModel(for: "base") { resource in resource.id }
        #expect(await cache.residentCountForTests == 1)

        await cache.forget("base")
        #expect(await cache.residentCountForTests == 0)
        for _ in 0..<100 where await unloads.value == 0 {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await unloads.value == 1, "the resident model was forgotten but never unloaded")

        // And a later acquire loads afresh rather than reusing it.
        _ = try await cache.withModel(for: "base") { resource in resource.id }
        #expect(await loads.value == 2)
    }

    /// A dictation in flight when the file is deleted must finish on the pages
    /// it already holds, and the model must be gone once it lets go — the same
    /// contract `invalidate` has, reached without awaiting.
    @Test("forgetting a model that is in use defers the unload to the last release")
    func forgettingAnActiveModelDefersTheUnload() async throws {
        let gate = Gate()
        let unloads = Counter()
        let cache = WhisperModelCache<String, FakeResource>(idleDuration: .seconds(60)) { key in
            FakeResource(id: key, unloads: unloads)
        }

        let task = Task { try await cache.withModel(for: "base") { _ in await gate.hold() } }
        for _ in 0..<1000 where await gate.entered == false { await Task.yield() }
        #expect(await gate.entered)

        await cache.forget("base")
        // Still in the cache, flagged: unloading now would pull the model out
        // from under the running decode.
        #expect(await cache.residentCountForTests == 1)
        #expect(await unloads.value == 0)

        await gate.release()
        _ = try await task.value
        #expect(await unloads.value == 1)
        #expect(await cache.residentCountForTests == 0)
    }

    /// The invalidated flag is a promise that the resource behind it gets
    /// unloaded exactly once, by whoever takes it out of the map. A second
    /// acquire that arrives before the first lets go must not quietly displace
    /// that entry, because then the original holder's release finds a different
    /// entry, decrements *its* count, and the displaced resource is never
    /// unloaded at all.
    @Test("an acquire during an in-flight forget does not orphan the old model")
    func acquireDuringForgetDoesNotOrphan() async throws {
        let gate = Gate()
        let unloads = Counter()
        let cache = WhisperModelCache<String, FakeResource>(idleDuration: .milliseconds(20)) { key in
            FakeResource(id: key, unloads: unloads)
        }

        // A dictation in flight, holding the resident model.
        let first = Task { try await cache.withModel(for: "base") { _ in await gate.hold() } }
        for _ in 0..<1000 where await gate.entered == false { await Task.yield() }
        #expect(await gate.entered)

        // The file is deleted underneath it: flagged, still mapped.
        await cache.forget("base")
        #expect(await unloads.value == 0)

        // A new caller arrives before the old one has let go, so the load takes
        // the key and the still-borrowed entry is displaced.
        _ = try await cache.withModel(for: "base") { resource in resource.id }
        #expect(await cache.residentCountForTests == 2,
                "the displaced model is still resident, so it must still be counted")

        await gate.release()
        _ = try await first.value

        // Both models were loaded and both have to end up unloaded. Before the
        // fix the displaced one was orphaned: its holder released against the
        // entry that had taken the key, and nothing was left to unload it.
        for _ in 0..<200 where await unloads.value < 2 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(await unloads.value == 2, "a loaded model was orphaned by a concurrent acquire")
        #expect(await cache.residentCountForTests == 0)
    }

    private actor Gate {
        private(set) var entered = false
        private var isOpen = false
        func hold() async {
            entered = true
            while !isOpen { await Task.yield() }
        }
        func release() { isOpen = true }
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
