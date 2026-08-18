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
    case translating
    case inserting
    case result(String)
    case failure(String)
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
