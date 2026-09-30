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
        var valid = Data("GGUF".utf8)
        valid.append(Data(repeating: 7, count: 4092))
        try valid.write(to: src)
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

        let previous = LocalModel.cleanupSelected
        LocalModel.cleanupSelected = m
        LocalModel.removeCustom(m)
        #expect(!FileManager.default.fileExists(atPath: m.localURL.path), "file survived removal")
        #expect(LocalModel.custom.count == before)
        #expect(LocalModel.cleanupSelected == nil, "removed model remained selected")
        LocalModel.cleanupSelected = previous
    }

    @Test("Importing a non-GGUF file fails before registration")
    func rejectsNonGGUFImport() throws {
        let src = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("not-a-model-\(UUID().uuidString)")
        try Data(repeating: 7, count: 4096).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        #expect(throws: TranslationEngineError.self) {
            try LocalModel.addCustom(importing: src)
        }
    }

    @Test("Built-ins are never removable from the catalogue and all have sources")
    func builtInsAreStable() {
        #expect(LocalModel.builtIn.count == 2)
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
        #expect(LocalModel.suggested?.label == "Gemma 3 1B")
        #expect(LocalModel.builtIn.allSatisfy { !$0.label.lowercased().contains("qwen") })
    }

    /// The contract this file used to assert was the opposite: an unset or stale
    /// preference resolved to the recommended model. That is exactly what made a
    /// fresh install show a large cleanup model selected, with its advertised
    /// size beside it, on a Mac that had never downloaded it.
    @Test("Nothing is selected until the user selects something")
    func nothingIsPreselected() {
        let defaults = UserDefaults.standard
        let savedLegacy = defaults.string(forKey: "qwenModelFile")
        let savedCleanup = defaults.string(forKey: "cleanupModelFile")
        defer {
            savedLegacy.map { defaults.set($0, forKey: "qwenModelFile") }
                ?? defaults.removeObject(forKey: "qwenModelFile")
            savedCleanup.map { defaults.set($0, forKey: "cleanupModelFile") }
                ?? defaults.removeObject(forKey: "cleanupModelFile")
        }

        defaults.removeObject(forKey: "qwenModelFile")
        defaults.removeObject(forKey: "cleanupModelFile")
        #expect(LocalModel.selected == nil, "a fresh install must have no model chosen")

        defaults.set("", forKey: "cleanupModelFile")
        #expect(LocalModel.selected == nil, "an empty stored name is not a choice")

        // A model that has left the catalogue reads as nothing, not as a silent
        // substitute — a swap the user never made is worse than an empty slot.
        defaults.set("no-longer-exists.gguf", forKey: "cleanupModelFile")
        #expect(LocalModel.selected == nil)

        let real = LocalModel.builtIn[0]
        defaults.removeObject(forKey: "cleanupModelFile")
        defaults.set(real.file, forKey: "qwenModelFile")
        #expect(LocalModel.cleanupSelected?.file == real.file)
        #expect(defaults.string(forKey: "cleanupModelFile") == real.file)

        // An explicit choice survives before download, and clearing it removes
        // both the new key and the legacy key.
        LocalModel.cleanupSelected = real
        LocalModel.cleanupSelected = nil
        #expect(defaults.string(forKey: "cleanupModelFile") == nil,
                "clearing the selection must remove the key, not store an empty one")
        #expect(defaults.string(forKey: "qwenModelFile") == nil)
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

        #expect(ASREngine.allCases == [.nemotron, .qwen06, .qwen17, .whisperTurbo])
        #expect(ASREngine.userSelectableCases == [.nemotron, .qwen06, .qwen17])
        // The Whisper turbo case survives so its 626 MB keeps a registry row and
        // a Delete button, but it is not offered, and a stored preference for it
        // must normalize away rather than silently select a model the user can
        // no longer see or change.
        #expect(!ASREngine.userSelectableCases.contains(.whisperTurbo),
                "Whisper turbo measured 3.6-4.6x real time and starves the reconciler; it must not be pickable")
        #expect(ASREngine.visibleSelection(.whisperTurbo) == nil)
        ASREngine.selected = .whisperTurbo
        #expect(ASREngine.selected == nil)
        #expect(UserDefaults.standard.string(forKey: "asrEngine") == nil)
        #expect(ASREngine.allCases.contains(.whisperTurbo),
                "the case must stay in allCases or its 626 MB reads as stray bytes")
        #expect(ASREngine.primaryCases == [.nemotron])
        #expect(QwenASREngine.extending("", with: "Hello.") == "Hello.")
        #expect(QwenASREngine.extending("Hello.", with: " Again") == "Hello. Again")
        #expect(QwenASREngine.extending("Hello.", with: "  ") == "Hello.")
        #expect(ASREngine.recommended == .nemotron)
        // The retired engine stays unselectable, and setting it must not fall
        // back to a model the user never chose.
        #expect(ASREngine.visibleSelection(.parakeetEou) == nil)
        ASREngine.selected = .parakeetEou
        #expect(ASREngine.selected == nil)
        #expect(ASREngine.effective == .nemotron)
        #expect(UserDefaults.standard.string(forKey: "asrEngine") == nil)
        ASREngine.selected = nil
        #expect(UserDefaults.standard.string(forKey: "asrEngine") == nil)

        // An unrecognised stored value reads as unset rather than as a
        // substitute, which is what makes removing an enum case safe.
        UserDefaults.standard.set("whisper-that-no-longer-exists", forKey: "asrEngine")
        #expect(ASREngine.selected == nil)
    }

    @Test("Nothing is badged in use before it is downloaded")
    func nothingClaimsToBeInUseWhenEmpty() {
        // "Nothing chosen" has to mean nothing on EITHER surface. Recognition
        // has two independent preferences now — the caption engine and its
        // Nemotron tier, plus dictation's engine and its own tier — and a Nemotron
        // tier is badged "in use" when either of them names it. Clearing only
        // `asrEngine` left a machine that had picked a tier (and a dictation
        // engine) still looking "in use" to this test, which is not a fresh
        // install at all.
        let keys = ["asrEngine", "translationEngine", "qwenModelFile", "cleanupModelFile",
                    "dictationStreamingEngine", "dictationRecognizer",
                    NemotronEngine.captionTierKey, NemotronEngine.dictationTierKey]
        let snapshot = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer {
            snapshot.forEach { key, value in
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        for k in keys {
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

    /// A model filename is one path component, whatever arrived.
    ///
    /// `URL.lastPathComponent` percent-DECODES, so a pasted custom-model URL
    /// ending in `a%2F..%2F..%2Fevil.gguf` hands back `a/../../evil.gguf` —
    /// which, joined onto the models directory, resolves outside it, and the
    /// downloader then creates directories and replaces files there in full
    /// trust. The user pastes the URL, but "the link I was given wrote
    /// outside the app's folder" is not something this app may allow.
    @Test("A custom model's filename cannot escape the models directory")
    func filenamesStayInsideTheModelsDirectory() {
        let root = URL(fileURLWithPath: "/tmp/models")
        let hostile = [
            "a%2F..%2F..%2Fevil.gguf",     // encoded separators
            "..%2F..%2Fboom.gguf",
            "../../escape.gguf",           // already decoded
            "sub/dir/model.gguf",
            "..",
            "",
        ]
        for raw in hostile {
            let decoded = URL(string: "https://h/\(raw)")?.lastPathComponent ?? raw
            let safe = LocalModel.safeFilename(decoded)
            #expect(!safe.isEmpty)
            #expect(!safe.contains("/"), "\(raw) -> \(safe) kept a separator")
            // The property that actually matters — and the only one worth
            // asserting. Dots INSIDE a name are harmless ("a_.._evil.gguf"
            // is one component); what must never happen is the joined path
            // resolving anywhere but this directory. Asserting "contains no
            // .." instead would be testing a proxy, and would fail on a name
            // that is perfectly safe.
            let resolved = root.appendingPathComponent(safe).standardized
            #expect(resolved.deletingLastPathComponent().path == root.path,
                    "\(raw) resolved to \(resolved.path)")
            // And a name that is nothing but dots is not a name at all: it
            // would resolve to the parent directory itself.
            #expect(safe != ".." && safe != ".", "\(raw) -> \(safe)")
        }
        // Ordinary names survive untouched.
        #expect(LocalModel.safeFilename("qwen2.5-3b-instruct-q4.gguf")
                == "qwen2.5-3b-instruct-q4.gguf")
    }
}
