import Foundation

/// Owns the one-time migration and storage contract for dictation's language
/// target. The migration marker matters even when the inherited target is Off:
/// a later captions change must not silently opt dictation into translation.
enum DictationTargetPreference {
    static let targetKey = "dictationTranslateTo"
    static let migratedKey = "dictationTranslateToMigrated"

    static func load(from defaults: UserDefaults = .standard) -> String? {
        if !defaults.bool(forKey: migratedKey) {
            if let inherited = defaults.string(forKey: "translateTo") {
                defaults.set(inherited, forKey: targetKey)
            } else {
                defaults.removeObject(forKey: targetKey)
            }
            defaults.set(true, forKey: migratedKey)
        }
        return defaults.string(forKey: targetKey)
    }

    static func save(_ value: String?, to defaults: UserDefaults = .standard) {
        if let value {
            defaults.set(value, forKey: targetKey)
        } else {
            defaults.removeObject(forKey: targetKey)
        }
    }
}

enum TranslationMenuScope: Equatable, Sendable {
    case captions
    case dictation
}

/// Which settings surface owns a translator choice. The implementations are
/// shared, but the user preferences must remain independently selectable.
enum TranslationEngineScope: String, Hashable, Sendable {
    case captions
    case dictation
}

struct TranslationMenuSelection: Equatable, Sendable {
    let scope: TranslationMenuScope
    let code: String?
}

struct TranslationMenuEntry: Equatable, Sendable {
    let selection: TranslationMenuSelection
    let isSelected: Bool
}

enum TranslationMenuModel {
    /// Builds one short, deterministic menu for either translation surface.
    /// The caller supplies the scope-specific current and recent values; no
    /// captions preference can leak into the dictation menu.
    static func entries(scope: TranslationMenuScope,
                        currentTarget: String?,
                        recentTargets: [String],
                        preferredLanguages: [String],
                        fallbackLanguages: [String]) -> [TranslationMenuEntry] {
        var codes: [String?] = [nil]
        var seen = Set<String>()

        func add(_ code: String?) {
            guard let code, !code.isEmpty, seen.insert(code).inserted else { return }
            codes.append(code)
        }

        add(currentTarget)
        recentTargets.forEach(add)
        preferredLanguages.forEach(add)
        fallbackLanguages.forEach(add)

        return codes.map {
            TranslationMenuEntry(
                selection: TranslationMenuSelection(scope: scope, code: $0),
                isSelected: $0 == currentTarget)
        }
    }
}

/// The externally visible lifecycle of a short press-to-talk session.
enum DictationPhase: Equatable, Sendable {
    case idle
    case waitingForInputMonitoring
    case preparing
    case ready
    case starting
    case dictating
    case transcribing
    case cleaning
    case translating
    case inserting
    case limit
    case recovery(String)
    case result(String)
    case failure(String)
}

/// A small preset over the existing dictation controls. `custom` is derived
/// from the controls, so changing an individual setting never lies about the
/// active mode.
enum DictationProfile: String, CaseIterable, Sendable {
    case fast
    case balanced
    case accurate
    case custom

    var displayName: String {
        switch self {
        case .fast: return String(localized: "Fast")
        case .balanced: return String(localized: "Balanced")
        case .accurate: return String(localized: "Accurate")
        case .custom: return String(localized: "Custom")
        }
    }
}

/// Kept in memory only. It gives users a recovery path when cleanup or
/// translation changes wording without persisting microphone text by default.
struct DictationResultSnapshot: Equatable, Sendable {
    let rawText: String
    let outputText: String
    let wasCleaned: Bool
    let wasTranslated: Bool
    let cleanupUnavailable: Bool
    /// Metadata for the text currently shown in the result bubble. It is kept
    /// separate from rawText because a translated result no longer has the
    /// source regions' language mix.
    let languageMetadata: DictationLanguageMetadata?

    var originalForRecovery: String? {
        rawText.isEmpty || rawText == outputText ? nil : rawText
    }

    init(rawText: String, outputText: String, wasCleaned: Bool,
         wasTranslated: Bool, languageMetadata: DictationLanguageMetadata? = nil,
         cleanupUnavailable: Bool = false) {
        self.rawText = rawText
        self.outputText = outputText
        self.wasCleaned = wasCleaned
        self.wasTranslated = wasTranslated
        self.cleanupUnavailable = cleanupUnavailable
        self.languageMetadata = languageMetadata
    }
}

struct DictationToastPresentation: Equatable, Sendable {
    let label: String
    let value: String
}

struct RecentDictationResult: Equatable, Identifiable {
    let id: UUID
    let completedAt: Date
    let result: DictationResultSnapshot
    let delivery: TextInsertionResult

    static func retaining(_ entry: Self, in current: [Self], enabled: Bool) -> [Self] {
        guard enabled else { return [] }
        guard !entry.delivery.secureTargetObserved,
              !current.contains(where: { $0.id == entry.id }),
              entry.result.rawText.count + entry.result.outputText.count <= 100_000 else { return current }
        var values = Array((current + [entry]).suffix(5))
        while values.reduce(0, { $0 + $1.result.rawText.count + $1.result.outputText.count }) > 100_000 {
            values.removeFirst()
        }
        return values
    }
}

func usesOriginalText(bundleIdentifier: String?, exceptions: Set<String>) -> Bool {
    guard let bundleIdentifier else { return false }
    return exceptions.contains(bundleIdentifier)
}

extension DictationPhase {
    var toastPresentation: DictationToastPresentation {
        switch self {
        case .idle: return .init(label: "Dictation", value: "Idle")
        case .waitingForInputMonitoring: return .init(label: "Dictation", value: "Permission required")
        case .preparing: return .init(label: "Dictation", value: "Preparing")
        case .ready: return .init(label: "Dictation", value: "Ready")
        case .starting: return .init(label: "Dictation", value: "Starting")
        case .dictating: return .init(label: "Dictation", value: "Recording")
        case .transcribing: return .init(label: "Dictation", value: "Transcribing")
        case .cleaning: return .init(label: "Dictation", value: "Cleaning")
        case .translating: return .init(label: "Dictation", value: "Translating")
        case .inserting: return .init(label: "Dictation", value: "Inserting")
        case .limit: return .init(label: "Dictation", value: "Limit reached")
        case .recovery(let text), .result(let text), .failure(let text):
            return .init(label: "Dictation", value: text)
        }
    }
}

struct DictationCleanupConfiguration: Equatable, Sendable {
    let enabled: Bool
    static let disabled = Self(enabled: false)
}

struct DictationAudioSampleLimit: Sendable {
    /// Keep a long press usable for ordinary dictation while bounding the
    /// in-memory buffer passed to the batch recogniser.
    static let maximumSamples = 16_000 * 60
    enum Decision: Equatable, Sendable { case accepted, limited }
    private(set) var sampleCount = 0

    mutating func accepted(sampleCount: Int) -> Decision {
        guard sampleCount > 0, self.sampleCount < Self.maximumSamples else { return .limited }
        let remaining = Self.maximumSamples - self.sampleCount
        guard sampleCount <= remaining else {
            self.sampleCount = Self.maximumSamples
            return .limited
        }
        self.sampleCount += sampleCount
        return self.sampleCount == Self.maximumSamples ? .limited : .accepted
    }
}

@MainActor
enum DictationTerminal: Equatable {
    case open, released, limited, cancelled
    mutating func accept(_ value: Self) -> Bool {
        guard self == .open else { return false }
        self = value
        return true
    }
}

extension DictationPhase {
    var automaticallyDismissesToast: Bool {
        switch self {
        case .result, .failure:
            true
        default:
            false
        }
    }
}

/// The opt-in translation stage for one press-to-talk session.
///
/// The target is captured when the session finishes so changing caption
/// settings while the user is speaking cannot silently change the output.
struct DictationTranslationConfiguration: Equatable, Sendable {
    let enabled: Bool
    let target: String?

    static let disabled = Self(enabled: false, target: nil)
}

/// Small, value-type state machine for Control press/release transitions.
/// Modifier events can repeat or arrive after teardown, so both transitions
/// are deliberately idempotent.
struct DictationSessionState: Sendable {
    private(set) var isActive = false

    @discardableResult
    mutating func begin() -> Bool {
        guard !isActive else { return false }
        isActive = true
        return true
    }

    @discardableResult
    mutating func release() -> Bool {
        guard isActive else { return false }
        isActive = false
        return true
    }

    mutating func cancel() {
        isActive = false
    }
}

/// Accumulates final recognizer chunks without inventing punctuation or
/// changing the model's casing.
struct DictationTextAssembler: Sendable {
    private var chunks: [String] = []

    var finalText: String { chunks.joined(separator: " ") }

    mutating func append(_ chunk: String) {
        let cleaned = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        chunks.append(cleaned)
    }

    mutating func reset() {
        chunks.removeAll(keepingCapacity: false)
    }
}
