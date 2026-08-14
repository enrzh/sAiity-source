import SwiftUI

/// The trailing control for a downloadable model, everywhere one appears.
///
/// Progress + Cancel → Remove (partial) → Delete (installed) → Download. This
/// existed as three hand-written copies — Models page, the model picker sheet,
/// onboarding — each styled slightly differently, and adding Cancel would have
/// meant writing it three times. The registry already unified the data; this
/// unifies the view of it.
struct AssetControl: View {
    @Bindable var state: AppState
    let status: AssetStatus
    /// Onboarding shows a slightly larger Download button; everywhere else is
    /// compact.
    var prominent: Bool = false

    var body: some View {
        if state.activeDownload == status.asset.id {
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 2) {
                    if let f = state.downloadProgress?.fraction {
                        ProgressView(value: f).frame(width: 100)
                        Text("\(Int(f * 100))%").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                Button("Cancel") { state.cancelDownload() }
                    .controlSize(.small)
                    .help("Stop this download. The part already fetched is kept, and Download resumes from it.")
            }
        } else if status.isInstalled, status.asset.install != nil,
                  let reason = state.loadFailures[status.asset.id] {
            // Present on disk but refused to load. Without this row the
            // failure loops forever: every Start repeats the error while this
            // page keeps saying "installed" with only a generic Delete.
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(reason)
                Text("Damaged").font(.caption).foregroundStyle(.orange)
                Button("Re-download") {
                    Task { await state.redownload(status.asset) }
                }
                .controlSize(.small)
                .disabled(state.activeDownload != nil)
                .help("Delete the damaged files and fetch \(status.asset.title) again.")
                Button("Delete", role: .destructive) {
                    Task { await state.delete(status.asset) }
                }
                .controlSize(.small)
            }
        } else if status.isInstalled || status.isPartial {
            Button(status.isPartial ? "Remove" : "Delete", role: .destructive) {
                Task { await state.delete(status.asset) }
            }
            .controlSize(.small)
        } else if status.asset.install != nil {
            Button(prominent
                   ? "Download \(ModelRegistry.format(status.asset.advertisedBytes ?? 0))"
                   : "Download") {
                Task { await state.download(status.asset) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(prominent ? .regular : .small)
            .disabled(state.activeDownload != nil)
        }
    }
}
