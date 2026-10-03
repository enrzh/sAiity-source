import SwiftUI

/// Both pages edit the same local dictionary; old comma-separated entries stay valid.
struct VocabularyEditor: View {
    @State private var terms = DictationVocabulary.terms
    @State private var corrections = DictationVocabulary.corrections
    @State private var name = ""
    @State private var heard = ""
    @State private var replacement = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Names and terms").font(.headline)
            ForEach(terms, id: \.self) { term in
                HStack {
                    Text(verbatim: term).textSelection(.enabled)
                    Spacer()
                    Button("Remove", role: .destructive) {
                        DictationVocabulary.terms = terms.filter { $0 != term }
                    }
                    .accessibilityLabel(String(localized: "Remove") + " " + term)
                }
            }
            HStack {
                TextField("Name or term", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addName)
                Button("Add", action: addName)
                    .disabled(!canAddName)
                    .accessibilityLabel("Add name or term")
            }
            Text("Keep recognized names and technical terms spelled correctly. Shared with captions and dictation.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()
            Text("Corrections").font(.headline)
            ForEach(corrections) { correction in
                HStack {
                    Text(verbatim: correction.heard).textSelection(.enabled)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        .accessibilityLabel("Replace with")
                    Text(verbatim: correction.replacement).textSelection(.enabled)
                    Spacer()
                    Button("Remove", role: .destructive) {
                        DictationVocabulary.corrections = corrections.filter { $0.id != correction.id }
                    }
                    .accessibilityLabel(String(localized: "Remove correction for") + " " + correction.heard)
                }
            }
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Heard phrase").font(.caption)
                    TextField(text: $heard, prompt: Text(verbatim: "Ube Eats")) { Text("Heard phrase") }
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Heard phrase")
                        .onSubmit(addCorrection)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Replace with").font(.caption)
                    TextField(text: $replacement, prompt: Text(verbatim: "Uber Eats")) { Text("Replace with") }
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Replace with")
                        .onSubmit(addCorrection)
                }
                Button("Add", action: addCorrection)
                    .disabled(!canAddCorrection)
                    .accessibilityLabel("Add correction")
            }
            Text("Only phrases you add are replaced. Up to 50 names and 50 corrections, 64 characters per field. Nothing is learned automatically.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            terms = DictationVocabulary.terms
            corrections = DictationVocabulary.corrections
        }
        .onReceive(NotificationCenter.default.publisher(for: DictationVocabulary.changed)) { _ in
            terms = DictationVocabulary.terms
            corrections = DictationVocabulary.corrections
        }
    }

    private var canAddName: Bool {
        DictationVocabulary.validEntry(name) && terms.count < 50
            && !terms.contains { $0.compare(name.trimmingCharacters(in: .whitespacesAndNewlines),
                                           options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    private var canAddCorrection: Bool {
        DictationVocabulary.validEntry(heard) && DictationVocabulary.validEntry(replacement)
            && corrections.count < 50 && heard.trimmingCharacters(in: .whitespacesAndNewlines)
                != replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            && !corrections.contains { $0.id == DictationVocabulary.Correction(heard: heard.trimmingCharacters(in: .whitespacesAndNewlines), replacement: replacement).id }
    }

    private func addName() {
        guard canAddName else { return }
        DictationVocabulary.terms = terms + [name]
        name = ""
    }

    private func addCorrection() {
        guard canAddCorrection else { return }
        DictationVocabulary.corrections = corrections + [.init(heard: heard, replacement: replacement)]
        heard = ""
        replacement = ""
    }
}
