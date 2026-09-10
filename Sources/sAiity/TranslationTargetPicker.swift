import AppKit
import SwiftUI

/// Choose what captions are translated into, from what the selected engine can
/// actually do.
///
/// The app used to offer two hardcoded lists that disagreed with each other —
/// 12 languages in the menu bar, 16 in Settings — and no way to reach anything
/// else. MADLAD alone can reach around 450, including the Asian and African
/// languages that were simply unreachable before.
///
/// Languages the current engine cannot do are still listed, but in their own
/// section with the engines that CAN do them offered as buttons. Hiding them
/// would leave the user believing the app cannot translate their language;
/// greying them out would say the same thing more quietly.
struct TranslationTargetPicker: View {
    @Bindable var state: AppState
    @Binding var target: String?
    let title: LocalizedStringKey
    let scope: TranslationEngineScope
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var supported: Set<String> = []
    @State private var loading = true

    private var matches: [AppLanguage] {
        LanguageCatalog.all.filter { $0.matches(query) }
    }
    private var available: [AppLanguage] { matches.filter { supported.contains($0.code) } }
    private var recommendedAvailable: [AppLanguage] {
        available.filter { engine != .qwen || LLMLanguageProvider.isStrong($0.code) }
    }
    private var experimentalAvailable: [AppLanguage] {
        available.filter { engine == .qwen && !LLMLanguageProvider.isStrong($0.code) }
    }
    private var elsewhere: [AppLanguage] { matches.filter { !supported.contains($0.code) } }

    /// Whose language coverage this list reflects.
    ///
    /// With no translator chosen the sheet still has to list something, so it
    /// previews the recommended one and says so in the subtitle — an empty list
    /// would leave the user with no way to understand why.
    private var configuredEngine: TranslationEngine? {
        switch scope {
        case .captions: return state.translationEngine
        case .dictation: return state.dictationTranslationEngine
        }
    }
    private var engine: TranslationEngine {
        configuredEngine
            ?? (scope == .dictation ? TranslationEngine.dictationEffective : nil)
            ?? .recommended
    }

    init(state: AppState,
         target: Binding<String?>,
         title: LocalizedStringKey = "Translate captions to",
         scope: TranslationEngineScope = .captions) {
        self.state = state
        self._target = target
        self.title = title
        self.scope = scope
    }

    var body: some View {
        SheetShell(title: title,
                   subtitle: configuredEngine == nil
                       && !(scope == .dictation && TranslationEngine.visibleSelection(TranslationEngine.selected) != nil)
                       ? "\(engine.displayName) — recommended, not chosen yet"
                       : "Using \(engine.displayName)",
                   width: 500, height: 560) {
            // A macOS .searchable installs into a toolbar, which a bare sheet
            // does not have — so the field is explicit.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search \(LanguageCatalog.all.count) languages", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            Divider()

            if loading {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            } else {
                list
            }
        }
        // The task identity cancels stale work when the engine changes. The
        // capability lookup itself is synchronous static metadata.
        .task(id: "\(scope)|\(engine.rawValue)") { loadSupported() }
    }

    private var list: some View {
        List {
            if !recommendedAvailable.isEmpty {
                Section("Available with \(engine.displayName)") {
                    ForEach(recommendedAvailable) { row($0) }
                }
            }
            if !experimentalAvailable.isEmpty {
                Section("Experimental with \(engine.displayName)") {
                    ForEach(experimentalAvailable) { row($0, experimental: true) }
                }
            }
            if !elsewhere.isEmpty {
                Section("Needs a different translator") {
                    ForEach(elsewhere) { unsupportedRow($0) }
                }
            }
            if available.isEmpty && elsewhere.isEmpty {
                Text("No language matches “\(query)”.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset)
    }

    private func row(_ lang: AppLanguage, experimental: Bool = false) -> some View {
        // A real Button, not an onTapGesture on a passive view: gestures are
        // invisible to the keyboard and to VoiceOver, so the menu bar's "All
        // languages…" opened a sheet a keyboard user could not operate at all.
        Button {
            target = lang.code
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(lang.displayName)
                    if experimental {
                        Text("Experimental quality — verify important translations.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if target == lang.code {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(target == lang.code ? .isSelected : [])
        .padding(.vertical, 1)
    }

    private func unsupportedRow(_ lang: AppLanguage) -> some View {
        HStack {
            Text(lang.displayName).foregroundStyle(.secondary)
            Spacer()
            AlternativeEngines(state: state, target: $target, language: lang,
                               scope: scope,
                               dismiss: { dismiss() })
        }
        .padding(.vertical, 1)
    }

    private func loadSupported() {
        loading = true
        supported = LanguageCatalog.supportedCodes(for: engine)
        loading = false
    }
}

/// Shown on the Captions page when the selected target is one the selected
/// engine cannot reach — which is easy to arrive at, since the target survives
/// an engine change. Offers the swap rather than only naming the problem.
struct TargetUnsupportedNotice: View {
    @Bindable var state: AppState
    let target: String

    @State private var engines: [TranslationEngine] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("\((state.translationEngine ?? .recommended).displayName) cannot translate into \(AppLanguage(code: target).displayName).",
                  systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(Color.orange)
            if engines.isEmpty {
                Text("No available translator covers this language.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    ForEach(engines, id: \.self) { e in
                        Button("Use \(e.displayName)") { state.translationEngine = e }
                            .controlSize(.small)
                    }
                }
            }
        }
        .task(id: "\(target)|\(state.translationEngine?.rawValue ?? "recommended")") {
            engines = await LanguageCatalog.engines(supporting: target)
                .filter { $0 != state.translationEngine }
        }
    }
}

/// The engines that can translate into a language the current one cannot, as
/// one-tap switches. Loaded per row on appear, because the answer depends on an
/// async query to Apple's framework.
private struct AlternativeEngines: View {
    @Bindable var state: AppState
    @Binding var target: String?
    let language: AppLanguage
    let scope: TranslationEngineScope
    let dismiss: () -> Void

    @State private var engines: [TranslationEngine] = []

    private var configuredEngine: TranslationEngine? {
        switch scope {
        case .captions: return state.translationEngine
        case .dictation: return state.dictationTranslationEngine
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(engines, id: \.self) { e in
                Button("Use \(e.displayName)") {
                    // Set both at once: switching the engine and then hunting
                    // for the language again is the failure this replaces.
                    switch scope {
                    case .captions: state.translationEngine = e
                    case .dictation: state.dictationTranslationEngine = e
                    }
                    target = language.code
                    dismiss()
                }
                .controlSize(.small)
            }
        }
        .task {
            engines = await LanguageCatalog.engines(supporting: language.code)
                .filter { $0 != configuredEngine }
        }
    }
}
