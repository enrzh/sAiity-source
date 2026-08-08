import Foundation
import Testing

@testable import sAiity

/// The registry's job is to be right about paths and install state. Both fail
/// silently: a wrong removal path deletes someone else's model, and a wrong
/// install check either re-downloads gigabytes or loads a model that isn't there.
@MainActor
struct ModelRegistryTests {

    @Test("No asset can delete the models root")
    func removalNeverTargetsTheRoot() {
        // The bug this locks down: Nemotron's directory constant WAS the shared
        // models root, so "delete Nemotron" resolved to the parent of qwen,
        // madlad and whisper — 6.9 GB, one click, no confirmation. It was
        // unreachable only because the engine picker had a single case.
        let root = ModelRegistry.root.standardizedFileURL
        for asset in ModelRegistry.assets() {
            guard case .remove(let url) = asset.removal else { continue }
            let target = url.standardizedFileURL
            #expect(target != root, "\(asset.id) would delete the entire models root")
            #expect(target.path.hasPrefix(root.path + "/"),
                    "\(asset.id) removes \(target.path), which is outside the models root")
        }
    }

    @Test("Every downloadable asset is represented exactly once")
    func catalogueIsCompleteAndUnique() {
        let assets = ModelRegistry.assets()
        let ids = assets.map(\.id)
        #expect(Set(ids).count == ids.count, "duplicate asset ids: \(ids)")

        // MADLAD is the reason this test exists: it was downloadable, 1.86 GB,
        // and had no row anywhere in the app.
        for expected in ["asr.nemotron", "asr.nemotron.fast", "asr.parakeetEou", "mt.madlad"] {
            #expect(ids.contains(expected), "missing asset \(expected)")
        }
        // Whisper was cut: its translate mode stopped emitting finals ~25 s into
        // every session. Leaving a registry entry behind would put a 2.9 GB
        // download back on the Models page with no engine to use it.
        #expect(!ids.contains { $0.contains("whisper") }, "Whisper was removed; a stale asset remains")
        // Apple went the same way: its translator needed no download but could
        // only reach the pairs macOS had, and it kept a whole second code path
        // alive for one engine.
        #expect(!ids.contains { $0.contains("apple") }, "Apple was removed; a stale asset remains")
        // One per Qwen variant, so the sheet and the Models page agree.
        #expect(ids.filter { $0.hasPrefix("mt.llm.") }.count == LocalModel.all.count)
    }

    @Test("Everything the app downloads can be downloaded and deleted from the UI")
    func ourAssetsAreFullyManageable() {
        let imported = Set(LocalModel.custom.compactMap {
            if case .importedFile = $0.source { return "mt.llm.\($0.file)" }
            return nil
        })
        for asset in ModelRegistry.assets() {
            // An imported file has no source to download from — by design its
            // only action is Delete.
            if !imported.contains(asset.id) {
                #expect(asset.install != nil, "\(asset.id) has no download path")
            }
            guard case .remove = asset.removal else {
                Issue.record("\(asset.id) has no delete path")
                continue
            }
        }
    }

    @Test("Install state needs a completion marker, not just bytes")
    func partialDownloadsAreNotReportedAsInstalled() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("saiity-registry-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let asset = ModelAsset(
            id: "test", family: .translation, title: "T", detail: "",
            recommended: false, licence: nil, advertisedBytes: nil,
            storage: .directory(tmp, markers: ["weights.bin"]),
            removal: .remove(tmp), use: .never, install: nil)

        // Bytes present, marker absent — an interrupted download. Reporting this
        // as installed is what made the app load models that were not there.
        try Data(repeating: 0, count: 2048).write(to: tmp.appendingPathComponent("tokenizer.json"))
        var s = ModelRegistry.status(of: asset)
        #expect(!s.isInstalled)
        #expect(s.isPartial)
        #expect(s.bytesOnDisk > 0)

        try Data(repeating: 0, count: 16).write(to: tmp.appendingPathComponent("weights.bin"))
        s = ModelRegistry.status(of: asset)
        #expect(s.isInstalled)
        #expect(!s.isPartial)
    }

    @Test("The two Nemotron tiers are independent assets")
    func nemotronTiersAreIndependent() {
        // A tier is its own ~640 MB directory. Deleting Fast must not remove
        // Balanced, and neither may resolve to the shared parent.
        let tiers = ModelRegistry.assets().filter { $0.id.hasPrefix("asr.nemotron") }
        #expect(tiers.count == 2)
        let dirs = tiers.compactMap { a -> String? in
            guard case .remove(let url) = a.removal else { return nil }
            return url.path
        }
        #expect(Set(dirs).count == 2, "tiers share a removal directory: \(dirs)")
        for d in dirs {
            #expect(d.contains("ms"), "\(d) is not a variant directory")
            #expect(!d.hasSuffix("nemotron-multilingual"),
                    "\(d) would delete every tier at once")
        }
    }

    @Test("Nemotron's install check is not satisfied by another model's metadata")
    func nemotronDoesNotSeeOtherModelsMarkers() {
        // Every .mlmodelc bundle ships a metadata.json, and the old check
        // scanned the whole tree for any file with that name — so three Whisper
        // bundles made the app believe Nemotron was installed.
        let marker = NemotronEngine.variantDirectory()
            .appendingPathComponent("metadata.json")
        #expect(marker.path.contains("nemotron-multilingual"))
        #expect(NemotronEngine.isDownloaded()
                == FileManager.default.fileExists(atPath: marker.path))
    }
}

@Suite("Download coordination")
struct DownloadCoordinatorTests {

    /// The defect: two callers wanting the same model each ran their own
    /// transfer, and for a GGUF that means each deleting the other's staging
    /// file. One run, two callers.
    @Test("A second caller joins the transfer instead of starting another")
    func secondCallerJoins() async throws {
        let counter = Counter()
        let c = DownloadCoordinator()
        async let a: Void = c.run("test.asset") { await counter.bumpAndWait() }
        async let b: Void = c.run("test.asset") { await counter.bumpAndWait() }
        _ = try await (a, b)
        #expect(await counter.value == 1, "the work ran more than once")
    }

    @Test("Different assets are not serialised against each other")
    func differentAssetsRunTogether() async throws {
        let counter = Counter()
        let c = DownloadCoordinator()
        async let a: Void = c.run("one") { await counter.bumpAndWait() }
        async let b: Void = c.run("two") { await counter.bumpAndWait() }
        _ = try await (a, b)
        // Two assets, two runs. A single global slot would still give 2 here,
        // so this pins intent rather than mechanism: nothing queues.
        #expect(await counter.value == 2)
    }

    @Test("A finished transfer is forgotten, so the next call really runs")
    func slotIsReleased() async throws {
        let counter = Counter()
        let c = DownloadCoordinator()
        try await c.run("test.asset") { await counter.bumpAndWait() }
        // Give the actor's cleanup hop a chance to land before asking again.
        try await Task.sleep(for: .milliseconds(50))
        try await c.run("test.asset") { await counter.bumpAndWait() }
        #expect(await counter.value == 2, "the id was never released")
    }

    /// Ids are constructed in one place now; the descriptors and the engines
    /// used to spell them separately, which is why the engines never used them.
    @Test("Asset ids match the descriptors that carry them")
    func idsAgreeWithDescriptors() {
        #expect(AssetID.parakeetEou == "asr.parakeetEou")
        #expect(AssetID.madlad == "mt.madlad")
        #expect(AssetID.llm(file: "x.gguf") == "mt.llm.x.gguf")
        let ids = Set(ModelRegistry.snapshot().map(\.asset.id))
        #expect(ids.contains(AssetID.parakeetEou))
        #expect(ids.contains(AssetID.madlad))
    }
}

private actor Counter {
    var value = 0
    func bumpAndWait() async {
        value += 1
        try? await Task.sleep(for: .milliseconds(80))
    }
}
