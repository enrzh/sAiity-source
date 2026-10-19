import AVFoundation
import AppKit
import SwiftUI

/// Permissions, startup, troubleshooting and version: whether the app is set
/// up correctly, as opposed to what it does.
struct GeneralView: View {
    @Bindable var state: AppState
    var onDetailVisibilityChanged: (Bool) -> Void = { _ in }
    @State private var permissions = PermissionMonitor()
    @State private var diagnosticsRevision = 0
    @State private var showsCredits = false

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        guard let short else { return String(localized: "Development build") }
        return build.map { "\(short) (\($0))" } ?? short
    }

    /// Kept for the status summary tests and the menu bar: one line saying
    /// whether dictation can run, and if not, the first thing in the way.
    static func dictationStatusLabel(enabled: Bool,
                                     input: Bool?,
                                     accessibility: Bool?,
                                     modelReady: Bool,
                                     microphone: AVAuthorizationStatus) -> String {
        guard enabled else { return String(localized: "Off") }
        guard modelReady else { return String(localized: "Not downloaded yet — see Models.") }
        if microphone == .denied || microphone == .restricted { return String(localized: "Microphone access needed") }
        guard input == true else { return input == nil ? String(localized: "Checking…") : String(localized: "Permission required") }
        guard let accessibility else { return String(localized: "Checking…") }
        guard accessibility else { return String(localized: "Shortcut ready — Accessibility needed") }
        return microphone == .notDetermined ? String(localized: "Microphone requested on first use") : String(localized: "Ready")
    }

    var body: some View {
        Form {
            Section {
                ForEach(AppPermission.allCases) { permission in
                    PermissionRow(permission: permission, status: permissions.status(permission))
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("Everything runs on this Mac. Audio, text and transcripts never leave it.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Open at login", isOn: Binding(get: { state.launchAtLogin },
                                                       set: { state.setLaunchAtLogin($0) }))
                if !state.launchAtLoginNote.isEmpty {
                    Text(state.launchAtLoginNote)
                        .foregroundStyle(.orange)
                }
                LabeledContent("Setup") {
                    Button("Run Setup Again…") {
                        Onboarding.reset()
                        OnboardingWindowController.shared.show(state: state)
                    }
                }
            }

            troubleshooting

            Section("About") {
                LabeledContent("Version") {
                    Text(verbatim: version)
                        .textSelection(.enabled)
                }
                LabeledContent("Credits") {
                    Button("Show Credits…") { showsCredits = true }
                }
            }
        }
        .formStyle(.grouped)
        .task { await permissions.watch() }
        .task { await state.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: Diagnostics.changed)) { _ in
            diagnosticsRevision += 1
        }
        .sheet(isPresented: $showsCredits) { CreditsSheet() }
    }

    @ViewBuilder
    private var troubleshooting: some View {
        let _ = diagnosticsRevision
        Section {
            if let failure = Diagnostics.latestFailure {
                LabeledContent {
                    EmptyView()
                } label: {
                    Text("Last problem")
                    Text(verbatim: failure.reason)
                        .textSelection(.enabled)
                }
            } else {
                LabeledContent("Last problem") {
                    Text("None")
                        .foregroundStyle(.secondary)
                }
            }
            let lastRun = Diagnostics.recentLatestRun
            if !lastRun.isEmpty {
                DisclosureGroup("Last dictation") {
                    if let slowest = DiagnosticsTimingSummarizer.slowestStage(lastRun) {
                        Text(verbatim: DiagnosticsTimingSummarizer.slowestExplanation(slowest.operation))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(lastRun.reversed().enumerated()), id: \.offset) { _, timing in
                        LabeledContent(DiagnosticsTimingSummarizer.stageTitle(timing.operation),
                                       value: CaptionPerformanceCopy.duration(timing.seconds))
                    }
                }
            }
            LabeledContent {
                Button("Save Diagnostics…") { Diagnostics.save() }
            } label: {
                Text("Diagnostics")
                Text("One text file for bug reports, with timings and settings but never your words.")
            }
        } header: {
            Text("Troubleshooting")
        }
    }
}

/// The licences and credits for the models and libraries in this build.
private struct CreditsSheet: View {
    @State private var credits = ""

    var body: some View {
        SheetShell(title: "Credits",
                   subtitle: "Models and libraries used by Syllivra.",
                   width: 620, height: 520) {
            ScrollView {
                Text(verbatim: credits)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .task {
            if let url = Bundle.main.url(forResource: "Credits", withExtension: "txt"),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                credits = text
            } else {
                credits = String(localized: "Credits file missing from this build.")
            }
        }
    }
}
