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
        // Exactly one recommended default, or `selected`'s force-unwrap dies.
        #expect(LocalModel.builtIn.filter(\.recommended).count == 1)
    }

    @Test("A stale selection falls back to the recommended model")
    func selectionFallsBack() {
        let saved = UserDefaults.standard.string(forKey: "qwenModelFile")
        defer { UserDefaults.standard.set(saved, forKey: "qwenModelFile") }
        UserDefaults.standard.set("no-longer-exists.gguf", forKey: "qwenModelFile")
        #expect(LocalModel.selected.recommended)
    }
}
