import AppKit
import SwiftUI

/// Shared target/engine controls. Bindings keep each mode's preferences and
/// notification bridge in AppState; this view owns no copy of either value.
struct TranslationSettingsRows: View {
    @Binding var target: String?
    @Binding var engine: TranslationEngine
    let engines: [TranslationEngine]
    let chooseTarget: () -> Void

    var body: some View {
        HStack {
            Label("Translate to", systemImage: "character.book.closed")
            Spacer()
            Button(action: chooseTarget) {
                HStack(spacing: 4) {
                    Text(target.map { AppLanguage(code: $0).displayName } ?? String(localized: "Off"))
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
            }
            if target != nil {
                Button("Off") { target = nil }
                    .controlSize(.small)
            }
        }
        HStack {
            Label("Translate with", systemImage: "cpu")
            Spacer()
            Picker("Translate with", selection: $engine) {
                ForEach(engines, id: \.self) { engine in
                    Text(engine.displayName).tag(engine)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            // Available even with translation off: an engine's coverage may
            // determine the language the user chooses next.
            .help(engine.summary)
        }
    }
}

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
    private var elsewhere: [AppLanguage] { matches.filter { !supported.contains($0.code) } }

    /// Whose language coverage this list reflects.
    ///
    /// With no translator chosen the sheet still has to list something, so it
    /// previews the recommended one and says so in the subtitle — an empty list
    /// would leave the user with no way to understand why.
    private var configuredEngine: TranslationEngine? {
        let raw: TranslationEngine?
        switch scope {
        case .captions: raw = state.translationEngine
        case .dictation: raw = state.dictationTranslationEngine
        }
        return TranslationEngine.visibleSelection(raw)
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
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search \(LanguageCatalog.all.count) languages", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5)
            }
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
            if !available.isEmpty {
                Section("Available with \(engine.displayName)") {
                    ForEach(available) { row($0) }
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

    private func row(_ lang: AppLanguage) -> some View {
        // A real Button, not an onTapGesture on a passive view: gestures are
        // invisible to the keyboard and to VoiceOver, so the menu bar's "All
        // languages…" opened a sheet a keyboard user could not operate at all.
        Button {
            target = lang.code
            dismiss()
        } label: {
            HStack {
                Text(lang.displayName)
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

    private var currentEngine: TranslationEngine {
        TranslationEngine.visibleSelection(state.translationEngine) ?? .recommended
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("\(currentEngine.displayName) cannot translate into \(AppLanguage(code: target).displayName).",
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
        .task(id: "\(target)|\(currentEngine.rawValue)") {
            engines = await LanguageCatalog.engines(supporting: target)
                .filter { $0 != currentEngine }
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
        let raw: TranslationEngine?
        switch scope {
        case .captions: raw = state.translationEngine
        case .dictation: raw = state.dictationTranslationEngine
        }
        return TranslationEngine.visibleSelection(raw)
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
