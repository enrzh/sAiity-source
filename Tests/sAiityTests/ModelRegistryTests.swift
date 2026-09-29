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
        for asset in ModelRegistry.assets() + ModelRegistry.retiredAssets() {
            guard case .remove(let url) = asset.removal else {
                Issue.record("\(asset.id) has no removal path"); continue
            }
            let target = url.standardizedFileURL
            #expect(target != root, "\(asset.id) would delete the entire models root")
            #expect(target.path.hasPrefix(root.path + "/"),
                    "\(asset.id) removes \(target.path), which is outside the models root")
            // An asset that stages its transfer must delete the staging with it,
            // or the row that says "removed" has freed a rounding error.
            if let staging = asset.storage.staging {
                let staged = staging.standardizedFileURL
                #expect(staged != root, "\(asset.id) would delete the entire models root")
                #expect(staged.path.hasPrefix(root.path + "/"),
                        "\(asset.id) stages outside the models root: \(staged.path)")
                #expect(staged != target,
                        "\(asset.id) removes the same path twice — one of the two is a no-op")
            }
        }
    }

    @Test("Every downloadable asset is represented exactly once")
    func catalogueIsCompleteAndUnique() {
        let assets = ModelRegistry.assets()
        let ids = assets.map(\.id)
        #expect(Set(ids).count == ids.count, "duplicate asset ids: \(ids)")

        // MADLAD is the reason this test exists: it was downloadable, 1.86 GB,
        // and had no row anywhere in the app.
        for expected in ["asr.nemotron", "asr.nemotron.fast", "mt.madlad"] {
            #expect(ids.contains(expected), "missing asset \(expected)")
        }
        #expect(!ids.contains("asr.parakeetEou"))
        // Listed again: Hy-MT2 is a selectable engine, so its 1.1 GB download
        // belongs on the Models page next to MADLAD's 1.9 GB one.
        #expect(ids.contains("mt.hymt2.1.8b.q4"))
        // Caption Whisper was cut: its translate mode stopped emitting finals
        // ~25 s into every session, so a row for it would put a 2.9 GB
        // download back on the Models page with no engine to use it. The two
        // DICTATION models are a different engine and are listed, deliberately
        // narrow. Whisper large-v3-turbo is a different proposition again — a
        // 626 MB model behind a working, tested caption engine — and is listed
        // on purpose. What must not come back is the 2.9 GB one, and its id
        // prefix is kept clear so this check cannot be quietly satisfied by a
        // new model that happens to share a name with it.
        #expect(!ids.contains { $0.hasPrefix("asr.whisper.large") },
                "the cut caption Whisper is back; a stale asset remains")
        #expect(ids.filter { $0.hasPrefix("asr.whisper.") }.count == 2,
                "expected exactly the two dictation Whisper models")
        #expect(ids.contains(AssetID.whisperTurbo),
                "the caption second opinion needs a row, or its 626 MB reads as stray")
        #expect(!ids.contains { $0.contains("diarization") }, "Speaker diarization was removed; a stale asset remains")
        // Apple went the same way: its translator needed no download but could
        // only reach the pairs macOS had, and it kept a whole second code path
        // alive for one engine.
        #expect(!ids.contains { $0.contains("apple") }, "Apple was removed; a stale asset remains")
        // Cleanup models are catalogued separately from translation engines.
        #expect(ids.filter { $0.hasPrefix("mt.llm.") }.count == LocalModel.all.count)
    }

    /// The defect this pins: Whisper's dictation models were downloaded into
    /// the models root by a path no registry asset described, so the page called
    /// up to 1.5 GB of a model the user had deliberately installed "other
    /// files" and offered no Download, Resume or Delete for it.
    @Test("The Whisper dictation models are catalogued, not counted as stray")
    func whisperDictationModelsAreRegistered() {
        let ids = ModelRegistry.assets().map(\.id)
        for choice in WhisperDictationBackend.ModelChoice.allCases {
            #expect(ids.contains(AssetID.whisper(choice)),
                    "\(choice.rawValue) has no registry row, so its bytes read as stray")
        }
        let whisper = ModelRegistry.assets().filter { $0.id.hasPrefix("asr.whisper.") }
        #expect(whisper.count == WhisperDictationBackend.ModelChoice.allCases.count)
        for asset in whisper {
            #expect(asset.family == .recognition)
            // A dictation model is not a caption recommendation, and the page
            // sorts recommended rows to the top of the group.
            #expect(!asset.recommended, "\(asset.id) claims to be a first download")
            #expect(asset.install != nil, "\(asset.id) has no Download")
            #expect(asset.licence != nil, "\(asset.id) does not say whose weights these are")
            #expect(asset.advertisedBytes ?? 0 > 0, "\(asset.id) does not say what it costs")
            guard case .stagedDirectory(let final, let staging, let markers) = asset.storage else {
                Issue.record("\(asset.id) must stage its transfer beside the model"); continue
            }
            #expect(final == WhisperDictationBackend.modelFolder(for: .base)
                     || final == WhisperDictationBackend.modelFolder(for: .small))
            #expect(staging == WhisperDictationBackend.stagingDirectory(for: .base)
                     || staging == WhisperDictationBackend.stagingDirectory(for: .small))
            #expect(markers == WhisperDictationBackend.ModelChoice.requiredBundles)
        }
    }

    @Test("Translation assets keep advanced models out of the primary group")
    func translationAssetsHaveClearTiers() {
        let madlad = TranslationEngine.madlad.assetDescriptors
        let specialist = TranslationEngine.hyMT2.assetDescriptors
        let local = TranslationEngine.qwen.assetDescriptors

        #expect(madlad.allSatisfy { !$0.isAdvanced })
        #expect(specialist.allSatisfy { $0.isAdvanced })
        #expect(local.allSatisfy { $0.family == .cleanup })
        #expect(!local.contains { $0.title.lowercased().contains("qwen") })
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

    /// A directory asset that stages its transfer: the half-downloaded bytes
    /// are part of the asset for measuring, for the row's Resume control, and for
    /// Delete. Modelling them as somewhere else is how a page can say "no model
    /// downloaded" while 400 MB sits beside it, and how a Delete can free
    /// nothing at all.
    @Test("a staged asset measures, resumes and deletes its staging directory")
    func stagedDirectoryIsPartOfTheAsset() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("saiity-staged-test-\(UUID().uuidString)")
        let final = base.appendingPathComponent("model", isDirectory: true)
        let staging = base.appendingPathComponent("model.partial", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let unloaded = Flag()
        let asset = ModelAsset(
            id: "test.staged", family: .recognition, title: "T", detail: "",
            recommended: false, licence: nil, advertisedBytes: nil,
            storage: .stagedDirectory(final: final, staging: staging, markers: ["a.bin"]),
            removal: .remove(final), use: .never, install: nil,
            unload: { unloaded.set() })

        var s = ModelRegistry.status(of: asset)
        #expect(!s.isInstalled)
        #expect(!s.isPartial)
        #expect(s.bytesOnDisk == 0)

        // Staged bytes only: a partial worth resuming, measured honestly.
        try Data(repeating: 0, count: 4096)
            .write(to: staging.appendingPathComponent("half.bin"))
        s = ModelRegistry.status(of: asset)
        #expect(!s.isInstalled, "staged bytes were read as a complete model")
        #expect(s.isPartial)
        #expect(s.bytesOnDisk == 4096)

        // Completeness is judged on the model directory alone, and a leftover
        // staging directory does not stop it being installed.
        try FileManager.default.createDirectory(at: final, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 16).write(to: final.appendingPathComponent("a.bin"))
        s = ModelRegistry.status(of: asset)
        #expect(s.isInstalled)
        #expect(!s.isPartial)
        #expect(s.bytesOnDisk == 4096 + 16)

        #expect(ModelRegistry.remove(asset))
        #expect(unloaded.value, "the loaded runtime was not released before the delete")
        #expect(!FileManager.default.fileExists(atPath: final.path))
        #expect(!FileManager.default.fileExists(atPath: staging.path),
                "Delete freed the model and left the transfer behind")
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
                == (NemotronEngine.hasCompletionMarker()
                    || NemotronEngine.hasCompleteRuntimeFiles()))
        #expect(NemotronEngine.hasCompletionMarker()
                == FileManager.default.fileExists(
                    atPath: NemotronEngine.completionMarkerURL().path))
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

    /// The bug this exists for: the first version joined with
    /// `try await task.value`, which is NOT a cancellation point for the
    /// awaiting task — a caller cancelled 0.5 s into a 3 s transfer returned
    /// normally at 3.25 s. Since `stopAsync()` cancels the session task and then
    /// awaits it, that hung Stop for the length of a 634 MB download.
    @Test("A cancelled caller stops waiting instead of blocking on the transfer")
    func cancelledCallerReturnsPromptly() async throws {
        let c = DownloadCoordinator()
        let started = Date()
        let waiter = Task<Bool, Never> {
            do {
                try await c.run("slow") { try await Task.sleep(for: .seconds(5)) }
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        try await Task.sleep(for: .milliseconds(150))
        waiter.cancel()
        let threw = await waiter.value
        let elapsed = Date().timeIntervalSince(started)
        #expect(threw, "a cancelled caller must be resumed, not left waiting")
        #expect(elapsed < 2.0, "took \(elapsed)s — the caller was blocked on the transfer")
    }

    /// The other half: one caller leaving must not abort a transfer somebody
    /// else is still waiting for.
    @Test("A transfer survives one of two callers cancelling")
    func othersKeepTheTransfer() async throws {
        let counter = Counter()
        let c = DownloadCoordinator()
        let stayer = Task<Bool, Never> {
            do { try await c.run("shared") { await counter.bumpAndWait() }; return true }
            catch { return false }
        }
        try await Task.sleep(for: .milliseconds(30))
        let leaver = Task<Void, Never> {
            try? await c.run("shared") { await counter.bumpAndWait() }
        }
        try await Task.sleep(for: .milliseconds(30))
        leaver.cancel()
        let finished = await stayer.value
        #expect(finished, "the remaining caller lost its transfer when the other left")
        #expect(await counter.value == 1)
    }

    /// Ids are constructed in one place now; the descriptors and the engines
    /// used to spell them separately, which is why the engines never used them.
    @Test("Asset ids match the descriptors that carry them")
    func idsAgreeWithDescriptors() {
        #expect(AssetID.parakeetEou == "asr.parakeetEou")
        #expect(AssetID.madlad == "mt.madlad")
        #expect(AssetID.hyMT2 == "mt.hymt2.1.8b.q4")
        #expect(AssetID.llm(file: "x.gguf") == "mt.llm.x.gguf")
        #expect(AssetID.whisper(.base) == "asr.whisper.base")
        #expect(AssetID.whisper(.small) == "asr.whisper.small")
        #expect(Set(WhisperDictationBackend.ModelChoice.allCases.map(AssetID.whisper)).count == 2,
                "the two Whisper models must not share an id")
        let ids = Set(ModelRegistry.snapshot().map(\.asset.id))
        #expect(!ids.contains(AssetID.parakeetEou))
        #expect(ids.contains(AssetID.madlad))
        #expect(ids.contains(AssetID.hyMT2))
        #expect(ids.contains(AssetID.whisper(.base)))
        #expect(ids.contains(AssetID.whisper(.small)))
    }
}

/// A one-way latch, for hooks that have to be observable from a test body.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

private actor Counter {
    var value = 0
    func bumpAndWait() async {
        value += 1
        try? await Task.sleep(for: .milliseconds(80))
    }
}
