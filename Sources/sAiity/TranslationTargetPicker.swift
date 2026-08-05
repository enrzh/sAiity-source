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
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var supported: Set<String> = []
    @State private var loading = true

    private var matches: [AppLanguage] {
        LanguageCatalog.all.filter { $0.matches(query) }
    }
    private var available: [AppLanguage] { matches.filter { supported.contains($0.code) } }
    private var elsewhere: [AppLanguage] { matches.filter { !supported.contains($0.code) } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
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
        .frame(width: 500, height: 560)
        .task { await loadSupported() }
        .onChange(of: state.translationEngine) { Task { await loadSupported() } }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Translate captions to").font(.headline)
                Text("Using \(state.translationEngine.displayName)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Off") {
                state.translateTo = nil
                dismiss()
            }
            .controlSize(.small)
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }

    private var list: some View {
        List {
            if !available.isEmpty {
                Section("Available with \(state.translationEngine.displayName)") {
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
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(lang.displayName)
                if state.translationEngine == .qwen,
                   !QwenLanguageProvider.strongTier.contains(lang.code) {
                    Text("Outside Qwen's strongest languages — quality varies.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if state.translateTo == lang.code {
                Image(systemName: "checkmark").foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            state.translateTo = lang.code
            dismiss()
        }
        .padding(.vertical, 1)
    }

    private func unsupportedRow(_ lang: AppLanguage) -> some View {
        HStack {
            Text(lang.displayName).foregroundStyle(.secondary)
            Spacer()
            AlternativeEngines(state: state, language: lang, dismiss: { dismiss() })
        }
        .padding(.vertical, 1)
    }

    private func loadSupported() async {
        loading = true
        supported = await state.translationEngine.languages.supportedCanonicalCodes()
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
            Label("\(state.translationEngine.displayName) cannot translate into "
                  + "\(AppLanguage(code: target).displayName).",
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
        .task(id: target) {
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
    let language: AppLanguage
    let dismiss: () -> Void

    @State private var engines: [TranslationEngine] = []

    var body: some View {
        HStack(spacing: 6) {
            ForEach(engines, id: \.self) { e in
                Button("Use \(e.displayName)") {
                    // Set both at once: switching the engine and then hunting
                    // for the language again is the failure this replaces.
                    state.translationEngine = e
                    state.translateTo = language.code
                    dismiss()
                }
                .controlSize(.small)
            }
        }
        .task {
            engines = await LanguageCatalog.engines(supporting: language.code)
                .filter { $0 != state.translationEngine }
        }
    }
}
