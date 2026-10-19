import AppKit
import SwiftUI

/// Every model this app can put on disk, by what it is for, with one control
/// each: download, progress, or delete.
struct ModelsView: View {
    @Bindable var state: AppState

    /// Recommended first, otherwise registry order.
    private func assets(_ family: ModelAsset.Family) -> [AssetStatus] {
        state.assets.filter { $0.asset.family == family }
            .enumerated()
            .sorted { a, b in
                a.element.asset.recommended == b.element.asset.recommended
                    ? a.offset < b.offset
                    : a.element.asset.recommended
            }
            .map(\.element)
    }

    private var interruptedBytes: Int64 {
        state.assets.filter(\.isPartial).reduce(0) { $0 + $1.bytesOnDisk } + state.retiredPartialBytes
    }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    if state.isModelsLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(verbatim: state.ownedTotal)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    Text("Downloaded models")
                    Text("Models run on this Mac. Download what you use and delete what you don't.")
                }
                if let error = state.modelError {
                    Text(verbatim: error)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            familySection("Speech recognition", family: .recognition)
            familySection("Translation", family: .translation)
            if !assets(.cleanup).isEmpty {
                familySection("Dictation cleanup", family: .cleanup)
            }

            Section {
                if interruptedBytes > 0 {
                    LabeledContent {
                        Button("Clear…", action: confirmClearInterrupted)
                            .disabled(state.isModelsLoading || state.hasActiveDownloads)
                    } label: {
                        Text("Interrupted downloads")
                        Text(verbatim: ModelRegistry.format(interruptedBytes))
                    }
                }
                LabeledContent {
                    Button("Manage…") { state.showLocalModels = true }
                } label: {
                    Text("Other cleanup models")
                    Text("Add or forget your own local models.")
                }
                if state.ownedBytes > 0 {
                    LabeledContent("All models") {
                        Button("Remove All…", role: .destructive, action: confirmRemoveAll)
                    }
                }
                LabeledContent("Check again") {
                    Button("Refresh") {
                        Task { await state.refreshModelsAsync(force: true) }
                    }
                    .disabled(state.isModelsLoading)
                }
            }
        }
        .formStyle(.grouped)
        .task { await state.refreshModelsAsync() }
        .sheet(isPresented: $state.showLocalModels) { LocalModelsView(state: state) }
    }

    @ViewBuilder
    private func familySection(_ title: LocalizedStringKey, family: ModelAsset.Family) -> some View {
        Section(title) {
            if state.assets.isEmpty && state.isModelsLoading {
                Text("Checking downloaded models…")
                    .foregroundStyle(.secondary)
            }
            ForEach(assets(family)) { status in
                row(status)
            }
        }
    }

    private func row(_ status: AssetStatus) -> some View {
        LabeledContent {
            AssetControl(state: state, status: status)
        } label: {
            Text(verbatim: status.asset.title)
            Text(verbatim: subtitle(status))
        }
        .help(help(status))
    }

    /// State first, then size: "In use · 634 MB", "Recommended · 634 MB to
    /// download". The long model notes live in the tooltip.
    private func subtitle(_ status: AssetStatus) -> String {
        var parts: [String] = []
        if status.asset.use.isSelected {
            parts.append(status.isInstalled ? String(localized: "In use") : String(localized: "Selected, not downloaded"))
        } else if status.asset.recommended {
            parts.append(String(localized: "Recommended"))
        }
        if status.isPartial {
            parts.append(String(localized: "\(ModelRegistry.format(status.bytesOnDisk)) of a download, can resume"))
        } else if status.isInstalled {
            parts.append(status.sizeText)
        } else if let bytes = status.asset.advertisedBytes {
            parts.append(String(localized: "\(ModelRegistry.format(bytes)) to download"))
        }
        if state.loadFailures[status.asset.id] != nil {
            parts.append(String(localized: "Damaged"))
        }
        return parts.joined(separator: " · ")
    }

    private func help(_ status: AssetStatus) -> String {
        [status.asset.detail, status.asset.licence].compactMap { $0 }.joined(separator: "\n\n")
    }

    private func confirmClearInterrupted() {
        let total = ModelRegistry.format(interruptedBytes)
        let a = NSAlert()
        a.messageText = String(localized: "Clear interrupted downloads?")
        a.informativeText = String(localized: "This frees \(total). Completed models stay installed.")
        a.alertStyle = .warning
        a.addButton(withTitle: String(localized: "Clear Interrupted"))
        a.addButton(withTitle: String(localized: "Cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        Task { _ = await state.clearInterruptedDownloads() }
    }

    private func confirmRemoveAll() {
        let total = ModelRegistry.format(state.ownedBytes)
        let a = NSAlert()
        a.messageText = String(localized: "Remove all downloaded models?")
        a.informativeText = String(localized: "This frees \(total).\n\nAnything you use again will be downloaded once more.")
        a.alertStyle = .warning
        a.addButton(withTitle: String(localized: "Remove All"))
        a.addButton(withTitle: String(localized: "Cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        Task { _ = await state.removeAllDownloads() }
    }
}
