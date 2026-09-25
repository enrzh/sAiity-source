import Foundation
import Testing

/// The catalog is maintained entirely by hand — every entry is
/// extractionState "manual" and build-app.sh just compiles it — so nothing in
/// the toolchain flags a missed key: a string that bypasses the catalog looks
/// exactly like a working translation until someone launches in German.
/// CONTRIBUTING.md documents four historical incidents of that class. These
/// tests encode the audit that used to be a periodic manual chore.
///
/// Honest limits, so nobody over-trusts a green run: the source scanner reads
/// only single-line `"…"` literals in the known localized contexts below —
/// triple-quoted strings, ternary literals like `Button(cond ? "A" : "B")`,
/// and producer-side `String(localized:)` values passed through variables are
/// out of its reach and are covered by the catalog-completeness half plus
/// review. It exists to catch the common case: a NEW plain literal in a
/// localized position that nobody added to the catalog.
struct LocalizationTests {

    @Test("Task6 settings keys have all shipped translations")
    func task6SettingsKeysAreComplete() throws {
        let required = ["Automatic", "Dictation cleanup", "Clean up dictated text", "Whisper dictation", "Whisper model", "Base", "Small", "Download", "Retry", "Remove", "Not ready", "Ready", "Preparing dictation", "Transcribing", "Cleaning up", "Dictation limit reached", "Permission required", "Open System Settings", "Reset Position", "Recovery", "Dictation failed", "Translated and inserted", "Inserted and copied", "Translation unavailable — cleaned text inserted and copied"]
        let strings = try Self.catalog()
        for key in required {
            guard let entry = strings[key], let localizations = entry["localizations"] as? [String: Any] else {
                Issue.record("missing catalog key: \(key)"); continue
            }
            for language in Self.shippedLanguages {
                #expect((localizations[language] as? [String: Any]) != nil, "missing \(language): \(key)")
            }
        }
    }

    // MARK: - Fixtures

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)                 // …/Tests/sAiityTests/LocalizationTests.swift
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func catalog() throws -> [String: [String: Any]] {
        let url = repoRoot.appendingPathComponent("Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj?["strings"] as? [String: [String: Any]] ?? [:]
    }

    private static func sourceFiles() throws -> [URL] {
        let dir = repoRoot.appendingPathComponent("Sources/sAiity")
        return try FileManager.default.contentsOfDirectory(at: dir,
                                                           includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Catalog completeness

    /// Every language the app ships. CFBundleLocalizations must agree.
    private static let shippedLanguages = ["de", "fr", "es", "ja"]

    @Test("Every catalog key is localized in every shipped language, or deliberately untranslatable")
    func catalogIsComplete() throws {
        let strings = try Self.catalog()
        #expect(strings.count > 300, "catalog looks truncated: \(strings.count) keys")

        var missing: [String] = []
        for (key, entry) in strings {
            if entry["shouldTranslate"] as? Bool == false { continue }
            for lang in Self.shippedLanguages {
                guard let loc = (entry["localizations"] as? [String: Any])?[lang]
                        as? [String: Any] else {
                    missing.append("\(lang): \(key)")
                    continue
                }
                // Every stringUnit reachable from this localization has to be
                // finished — including the ones nested inside plural
                // variations and per-argument substitutions. Accepting a
                // non-nil `variations` without looking inside it would pass an
                // empty dictionary, or a plural case a merge left at "new" or
                // "": exactly what a bulk translation import gets wrong.
                if !Self.isFinished(loc) { missing.append("\(lang): \(key)") }
            }
        }
        #expect(missing.isEmpty,
                "keys without a finished localization: \(missing.sorted())")
    }

    /// True when every stringUnit reachable from a localization node is
    /// state "translated" with a non-empty value, and at least one exists.
    private static func isFinished(_ node: [String: Any]) -> Bool {
        var seen = false
        func walk(_ any: Any) -> Bool {
            guard let dict = any as? [String: Any] else { return true }
            if let unit = dict["stringUnit"] as? [String: Any] {
                seen = true
                guard unit["state"] as? String == "translated",
                      let v = unit["value"] as? String, !v.isEmpty else { return false }
            }
            for (k, v) in dict where k != "stringUnit" {
                if !walk(v) { return false }
            }
            return true
        }
        return walk(node) && seen
    }

    // MARK: - Source scan

    /// Call sites whose first string literal is a LocalizedStringKey or
    /// String.LocalizationValue — i.e. a catalog KEY, not display text.
    private static let contexts = [
        "String(localized: ", "Text(", "Toggle(", "Button(", "Label(",
        "Section(", "TextField(", "Picker(", "LabeledContent(",
        "LabeledToggle(", "setStatus(", "bullet(", "slider(", ".help(",
        "ContentUnavailableView(", "Menu(", "SettingsSection(",
        // This codebase's own LocalizedStringKey-typed wrappers. SheetShell's
        // parameters carry a comment explaining that a String there would make
        // the header "silently stop being translated" — exactly the class of
        // miss this test exists to catch, and it was not being scanned.
        "SheetShell(title: ", "badge(", "textStyleSection(", "header(",
    ]

    @Test("Every scanned literal in a localized context resolves to a catalog key")
    func literalsResolveToCatalogKeys() throws {
        let keys = Set(try Self.catalog().keys)
        var misses: [String] = []

        for file in try Self.sourceFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (literal, line) in Self.scan(text) {
                // Symbols, spacing and format-only strings are not language.
                guard literal.contains(where: { $0.isLetter }) else { continue }
                let candidates = Self.keyCandidates(for: literal)
                if candidates.isDisjoint(with: keys) {
                    misses.append("\(file.lastPathComponent):\(line): \"\(literal)\"")
                }
            }
        }
        #expect(misses.isEmpty, """
            literals in localized contexts with no catalog key — add them to \
            Resources/Localizable.xcstrings (with German) or move them out of \
            a localized position:
            \(misses.joined(separator: "\n"))
            """)
    }

    @Test("No Text() built by string concatenation")
    func noConcatenatedText() throws {
        // `Text("a" + b)` binds the verbatim overload and silently stops
        // being translated — one of the four documented historical traps.
        let re = try NSRegularExpression(pattern: #"Text\("([^"\\]|\\.)*"\s*\+"#)
        for file in try Self.sourceFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            let hit = re.firstMatch(in: text,
                                    range: NSRange(text.startIndex..., in: text))
            #expect(hit == nil, "concatenated Text() in \(file.lastPathComponent)")
        }
    }

    // MARK: - The scanner

    /// Contexts whose FIRST literal is an SF Symbol name; the localized key
    /// is the second literal.
    private static let symbolFirst: Set<String> = ["bullet(", "header("]

    /// All (processed literal, line) pairs found after a known context token.
    /// Interpolations become a placeholder; escapes are resolved the way the
    /// key extractor resolves them.
    private static func scan(_ text: String) -> [(String, Int)] {
        var out: [(String, Int)] = []
        let chars = Array(text)
        for token in contexts {
            var search = text.startIndex
            while let r = text.range(of: token, range: search..<text.endIndex) {
                search = r.upperBound
                var i = text.distance(from: text.startIndex, to: r.upperBound)
                guard var parsed = literal(chars, at: &i) else { continue }
                if Self.symbolFirst.contains(token) {
                    // Past the symbol name: skip the separator to the text.
                    while i < chars.count, ", \n".contains(chars[i]) { i += 1 }
                    guard let second = literal(chars, at: &i) else { continue }
                    parsed = second
                }
                let line = text[..<r.lowerBound].reduce(into: 1) {
                    if $1 == "\n" { $0 += 1 }
                }
                out.append((parsed, line))
            }
        }
        return out
    }

    /// Parse one `"…"` literal starting at or after `i` (spaces allowed);
    /// advances `i` past its closing quote. Nil for anything but a plain
    /// single-line literal.
    private static func literal(_ chars: [Character], at i: inout Int) -> String? {
        // Whitespace INCLUDING newlines: Swift's line lengths regularly push
        // the string onto the line after its call. Skipping only spaces made
        // those call sites invisible — silently, which is the worst way for a
        // guard like this to fail.
        while i < chars.count, chars[i].isWhitespace { i += 1 }
        guard i < chars.count, chars[i] == "\"" else { return nil }
        // Triple-quoted strings are out of scope (documented above).
        if i + 2 < chars.count, chars[i + 1] == "\"", chars[i + 2] == "\"" {
            return nil
        }
        var j = i + 1
        guard let parsed = parseLiteral(chars, from: j, end: &j) else { return nil }
        i = j + 1
        return parsed
    }

    /// Parse from just after an opening quote to the closing quote, leaving
    /// `end` on the closing quote. Interpolations `\(…)` — including nested
    /// parens and nested string literals inside them — collapse to U+0001.
    private static func parseLiteral(_ chars: [Character], from start: Int,
                                     end: inout Int) -> String? {
        var i = start
        var outStr = ""
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                end = i
                return outStr
            }
            if c == "\n" { return nil }        // unterminated on this line
            if c == "\\" {
                guard i + 1 < chars.count else { return nil }
                let n = chars[i + 1]
                if n == "(" {
                    var depth = 1
                    i += 2
                    while i < chars.count, depth > 0 {
                        switch chars[i] {
                        case "(": depth += 1
                        case ")": depth -= 1
                        case "\"":
                            // A string inside the interpolation: skip it whole.
                            i += 1
                            while i < chars.count, chars[i] != "\"" {
                                if chars[i] == "\\" { i += 1 }
                                i += 1
                            }
                        default: break
                        }
                        i += 1
                    }
                    outStr.append("\u{0001}")
                    continue
                }
                switch n {
                case "n": outStr.append("\n")
                case "t": outStr.append("\t")
                case "\"": outStr.append("\"")
                case "\\": outStr.append("\\")
                default: outStr.append(n)
                }
                i += 2
                continue
            }
            outStr.append(c)
            i += 1
        }
        return nil
    }

    /// Every catalog key this literal could extract to: literal `%` doubles,
    /// and each interpolation is either `%@` or `%lld` — the two specifiers
    /// this codebase interpolates. 2ⁿ combinations, n is always small.
    private static func keyCandidates(for literal: String) -> Set<String> {
        // BOTH spellings of a literal %. String(localized:) escapes it to %%
        // in the extracted key; a plain Text("…100%…") with no interpolation
        // keys off the raw string. The scanner sees both context kinds, so a
        // candidate set that models only one produces false failures for the
        // other — and a test that cries wolf gets weakened, not fixed.
        var results: Set<String> = [literal,
                                    literal.replacingOccurrences(of: "%", with: "%%")]
        while let sample = results.first(where: { $0.contains("\u{0001}") }) {
            results.remove(sample)
            for spec in ["%@", "%lld"] {
                if let r = sample.range(of: "\u{0001}") {
                    results.insert(sample.replacingCharacters(in: r, with: spec))
                }
            }
        }
        return results
    }
}
