import Foundation

/// The externally visible lifecycle of a short press-to-talk session.
enum DictationPhase: Equatable, Sendable {
    case idle
    case waitingForInputMonitoring
    case ready
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
