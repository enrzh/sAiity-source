import Foundation
import Testing

@testable import sAiity

/// Custom models are user data: a wrong completeness answer either re-downloads
/// gigabytes or loads a truncated file, and a broken import silently loses the
/// model the user just added.
@MainActor
struct LocalModelTests {

    @Test("A truncated download of a known size is not reported complete")
    func knownSizeCatchesTruncation() throws {
        let dir = LocalModel.directory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "test-truncated-\(UUID().uuidString).gguf"
        let url = dir.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0, count: 1024).write(to: url)

        let m = LocalModel(source: .url("https://example.invalid/m.gguf"), file: name,
                           label: "t", bytes: 10_000_000, recommended: false,
                           note: "", licence: "")
        #expect(!m.isDownloaded, "1 KB of a 10 MB model read as complete")
    }

    @Test("Unknown size relies on staging: presence means a completed transfer")
    func unknownSizeContractIsExplicit() throws {
        // The contract, pinned: with no expected size, an existing destination
        // file counts as complete — safe ONLY because FileDownloader stages to
        // .part and never creates the destination until the transfer finished.
        // If staging is ever removed, this test is the reminder of what breaks.
        let dir = LocalModel.directory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "test-unknown-\(UUID().uuidString).gguf"
        let url = dir.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: url) }

        let m = LocalModel(source: .url("https://example.invalid/m.gguf"), file: name,
                           label: "t", bytes: nil, recommended: false, note: "", licence: "")
        #expect(!m.isDownloaded, "absent file read as complete")
        try Data(repeating: 0, count: 64).write(to: url)
        #expect(m.isDownloaded)
    }

    @Test("Importing a file copies it in and registers it; removing forgets both")
    func importRoundTrip() throws {
        let src = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sha256-\(UUID().uuidString)")   // Ollama-style, no extension
        try Data(repeating: 7, count: 4096).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        let before = LocalModel.custom.count
        let m = try LocalModel.addCustom(importing: src)
        defer { LocalModel.removeCustom(m) }

        #expect(m.file.hasSuffix(".gguf"), "imported blob did not get a usable extension")
        #expect(m.bytes == 4096)
        #expect(FileManager.default.fileExists(atPath: m.localURL.path), "copy did not land")
        #expect(LocalModel.custom.count == before + 1)
        #expect(LocalModel.all.contains { $0.file == m.file }, "not visible in the catalogue")
        #expect(m.downloadURL == nil, "an imported file has nothing to download")

        LocalModel.removeCustom(m)
        #expect(!FileManager.default.fileExists(atPath: m.localURL.path), "file survived removal")
        #expect(LocalModel.custom.count == before)
    }

    @Test("Built-ins are never removable from the catalogue and all have sources")
    func builtInsAreStable() {
        #expect(LocalModel.builtIn.count >= 6)
        for m in LocalModel.builtIn {
            #expect(m.downloadURL != nil, "\(m.file) has no download URL")
            #expect(m.bytes != nil && m.bytes! > 100 * 1_048_576,
                    "\(m.file) has an implausible size")
            #expect(!m.licence.isEmpty)
        }
        // Exactly one, because the UI names it as "the one to start with" and
        // two suggestions is not a suggestion.
        #expect(LocalModel.builtIn.filter(\.recommended).count == 1)
        #expect(LocalModel.suggested != nil)
    }

    /// The contract this file used to assert was the opposite: an unset or stale
    /// preference resolved to the recommended model. That is exactly what made a
    /// fresh install show Qwen3.5 2B selected, with its advertised size beside
    /// it, on a Mac that had never downloaded it — and turned the first Start
    /// into a 1.25 GB download nobody had agreed to.
    @Test("Nothing is selected until the user selects something")
    func nothingIsPreselected() {
        let saved = UserDefaults.standard.string(forKey: "qwenModelFile")
        defer { UserDefaults.standard.set(saved, forKey: "qwenModelFile") }

        UserDefaults.standard.removeObject(forKey: "qwenModelFile")
        #expect(LocalModel.selected == nil, "a fresh install must have no model chosen")

        UserDefaults.standard.set("", forKey: "qwenModelFile")
        #expect(LocalModel.selected == nil, "an empty stored name is not a choice")

        // A model that has left the catalogue reads as nothing, not as a silent
        // substitute — a swap the user never made is worse than an empty slot.
        UserDefaults.standard.set("no-longer-exists.gguf", forKey: "qwenModelFile")
        #expect(LocalModel.selected == nil)

        // An explicit choice survives, downloaded or not: the sheet is where you
        // both choose and download, so un-choosing on pick would be unusable.
        let real = LocalModel.builtIn[0]
        UserDefaults.standard.set(real.file, forKey: "qwenModelFile")
        #expect(LocalModel.selected?.file == real.file)

        LocalModel.selected = nil
        #expect(UserDefaults.standard.string(forKey: "qwenModelFile") == nil,
                "clearing the selection must remove the key, not store an empty one")
    }

    @Test("Engine selections start empty and round-trip through defaults")
    func engineSelectionsAreOptional() {
        let asr = UserDefaults.standard.string(forKey: "asrEngine")
        let mt = UserDefaults.standard.string(forKey: "translationEngine")
        defer {
            UserDefaults.standard.set(asr, forKey: "asrEngine")
            UserDefaults.standard.set(mt, forKey: "translationEngine")
        }

        UserDefaults.standard.removeObject(forKey: "asrEngine")
        UserDefaults.standard.removeObject(forKey: "translationEngine")
        #expect(ASREngine.selected == nil)
        #expect(TranslationEngine.selected == nil)
        // `effective` still answers, so the pipeline types stay non-optional —
        // it is never consulted before start() has checked `selected`.
        #expect(ASREngine.effective == ASREngine.recommended)
        #expect(TranslationEngine.effective == TranslationEngine.recommended)

        ASREngine.selected = .parakeetEou
        #expect(ASREngine.selected == .parakeetEou)
        #expect(ASREngine.effective == .parakeetEou)
        ASREngine.selected = nil
        #expect(UserDefaults.standard.string(forKey: "asrEngine") == nil)

        // An unrecognised stored value reads as unset rather than as a
        // substitute, which is what makes removing an enum case safe.
        UserDefaults.standard.set("whisper-that-no-longer-exists", forKey: "asrEngine")
        #expect(ASREngine.selected == nil)
    }

    @Test("Nothing is badged in use before it is downloaded")
    func nothingClaimsToBeInUseWhenEmpty() {
        let asr = UserDefaults.standard.string(forKey: "asrEngine")
        let mt = UserDefaults.standard.string(forKey: "translationEngine")
        let gguf = UserDefaults.standard.string(forKey: "qwenModelFile")
        defer {
            UserDefaults.standard.set(asr, forKey: "asrEngine")
            UserDefaults.standard.set(mt, forKey: "translationEngine")
            UserDefaults.standard.set(gguf, forKey: "qwenModelFile")
        }
        for k in ["asrEngine", "translationEngine", "qwenModelFile"] {
            UserDefaults.standard.removeObject(forKey: k)
        }
        // Every registry row, not a sample: the fresh-install lie was two rows
        // badged "in use" beside their own "634 MB to download" line.
        for a in ModelRegistry.snapshot() {
            #expect(!a.asset.use.isSelected,
                    "\(a.asset.id) claims to be selected with nothing chosen")
        }
        // And something is still suggested, or the user is told nothing at all.
        #expect(ModelRegistry.snapshot().contains { $0.asset.recommended })
    }
}
