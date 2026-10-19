import AppKit
import SwiftUI

/// Live captions for what the Mac plays: start them, choose the speech model
/// and translation, and set how the caption bubble looks.
struct CaptionsView: View {
    @Bindable var state: AppState
    var onDetailVisibilityChanged: (Bool) -> Void = { _ in }
    @State private var permissions = PermissionMonitor()
    @State private var diagnosticsRevision = 0
    @State private var showsAdvanced = false
    @State private var showsVocabulary = false

    var body: some View {
        Form {
            essentials
            translation
            bubble
            advanced
        }
        .formStyle(.grouped)
        .task { await permissions.watch() }
        .task { await state.refreshModelsAsync() }
        .task(id: "\(state.translateTo ?? "")|\(state.translationEngine?.rawValue ?? "none")") {
            await state.refreshTargetSupport()
        }
        .onReceive(NotificationCenter.default.publisher(for: Diagnostics.changed)) { _ in
            diagnosticsRevision += 1
        }
        .sheet(isPresented: $state.showLocalModels) { LocalModelsView(state: state) }
        .sheet(isPresented: $state.showTranslationPicker) {
            TranslationTargetPicker(state: state,
                                    target: $state.translateTo,
                                    title: "Translate captions to")
        }
        .sheet(isPresented: $showsVocabulary) {
            SheetShell(title: "Vocabulary",
                       subtitle: "Used by captions and dictation.",
                       width: 520, height: 460) {
                ScrollView {
                    VocabularyEditor()
                        .padding(16)
                }
            }
        }
    }

    // MARK: Essentials

    private var statusText: String {
        if CaptionSession.shared.isStopping { return String(localized: "Stopping…") }
        return state.isCaptioning
            ? String(localized: "Captions are running.")
            : String(localized: "Shows what your Mac is playing as text, on this Mac only.")
    }

    @ViewBuilder
    private var essentials: some View {
        Section {
            LabeledContent {
                Button {
                    NotificationCenter.default.post(name: .saiityToggleCaptions, object: nil)
                } label: {
                    Text(state.isCaptioning ? "Stop Captions" : "Start Captions")
                        .frame(minWidth: 110)
                }
                .buttonStyle(.borderedProminent)
                .disabled(CaptionSession.shared.isStopping)
            } label: {
                Text("Captions")
                Text(verbatim: statusText)
            }
            if CaptionSession.shared.translationBacklogged {
                Text("Translation is falling behind; some lines stay untranslated.")
                    .foregroundStyle(.orange)
            }
            ForEach(permissions.missing(for: .captions)) { permission in
                PermissionRow(permission: permission, status: permissions.status(permission))
            }
            Picker(selection: $state.engine) {
                Text("Not set").tag(Optional<ASREngine>.none)
                ForEach(ASREngine.userSelectableCases, id: \.self) { engine in
                    Text(verbatim: engine.displayName).tag(Optional(engine))
                }
            } label: {
                Text("Speech model")
                Text(verbatim: state.engine?.shortSummary
                     ?? String(localized: "Choose a model. \(ASREngine.recommended.displayName) is recommended."))
            }
            .help(state.engine?.summary ?? ASREngine.recommended.summary)
            if state.engine == .nemotron {
                Picker(selection: $state.nemotronTier) {
                    Text("Balanced").tag(2240)
                    Text("Realtime").tag(1120)
                } label: {
                    Text("Update speed")
                    Text(state.nemotronTier == 1120
                         ? "Words appear while someone is still speaking. Uses more power."
                         : "Updates every couple of seconds. Uses less power.")
                }
            }
            if let engine = state.engine, case .only(let codes) = engine.coverage {
                let names = codes.sorted()
                    .map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }
                Text("Recognises \(names.joined(separator: ", ")) only.")
                    .foregroundStyle(.orange)
            }
            ForEach(recognitionAssets, id: \.id) { asset in
                RequiredModelRow(state: state, asset: asset)
            }
        }
    }

    private var recognitionAssets: [ModelAsset] {
        guard let engine = state.engine else { return [] }
        return engine.assetDescriptors.filter {
            engine != .nemotron || $0.id == AssetID.nemotron(chunkMs: state.nemotronTier)
        }
    }

    // MARK: Translation

    private var translationEngine: TranslationEngine {
        state.translationEngine ?? .recommended
    }

    private var showsTranslation: Binding<Bool> {
        Binding(get: { state.style.showTranslation },
                set: { visible in
                    var updated = state.style
                    updated.showTranslation = visible
                    state.style = updated
                })
    }

    @ViewBuilder
    private var translation: some View {
        Section {
            TranslationTargetRow(title: "Translate to",
                                 target: $state.translateTo,
                                 recent: state.recentTargetsForMenu) {
                state.showTranslationPicker = true
            }
            if let target = state.translateTo {
                if !state.targetSupportedByEngine {
                    TargetUnsupportedNotice(state: state, target: target)
                }
                if let id = translationEngine.activeAssetID,
                   let asset = translationEngine.assetDescriptors.first(where: { $0.id == id }) {
                    RequiredModelRow(state: state, asset: asset)
                }
                Picker(selection: $state.translationTiming) {
                    ForEach(TranslationTiming.allCases, id: \.self) { timing in
                        Text(timing.displayName).tag(timing)
                    }
                } label: {
                    Text("Translation timing")
                    Text(state.translationTiming == .live
                         ? "Follows the words as they come and may change. Saved transcripts keep the final translation."
                         : "Appears when a sentence ends.")
                }
                Toggle("Show translation on screen", isOn: showsTranslation)
            }
        } header: {
            Text("Translation")
        }
    }

    // MARK: Bubble

    private var showsBubble: Binding<Bool> {
        Binding(get: { !state.style.hidden },
                set: { visible in
                    var updated = state.style
                    updated.hidden = !visible
                    state.style = updated
                })
    }

    @ViewBuilder
    private var bubble: some View {
        Section {
            Toggle(isOn: showsBubble) {
                Text("Show captions on screen")
                Text("Off keeps recognition and transcripts running with nothing on screen.")
            }
            if showsBubble.wrappedValue {
                BubbleStylePicker(style: $state.style, context: .captions)
                BubbleTextSizeSlider(style: $state.style, context: .captions)
                LabeledContent("Preview") {
                    HStack {
                        Button("Show Preview") {
                            NotificationCenter.default.post(name: .saiityCaptionPreview, object: nil)
                        }
                        Button("Reset Position") {
                            NotificationCenter.default.post(name: .saiityResetBubble, object: nil)
                        }
                    }
                }
            }
        } header: {
            Text("Caption bubble")
        }
    }

    // MARK: Advanced

    @ViewBuilder
    private var advanced: some View {
        Section {
            DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                Picker("Listen to", selection: $state.captureApp) {
                    Text("Everything the Mac plays").tag(String?.none)
                    ForEach(state.runningApps, id: \.bundleID) { app in
                        Text(verbatim: app.name).tag(Optional(app.bundleID))
                    }
                }
                Toggle(isOn: $state.includeMic) {
                    Text("Include my microphone")
                    Text("For calls: adds your own voice, which system audio does not carry.")
                }
                Toggle(isOn: $state.identifyCaptionSpeakers) {
                    Text("Identify speakers")
                    Text("Labels voices in captions and transcripts. Applies to the next session.")
                }
                .disabled(state.isCaptioning)
                if state.identifyCaptionSpeakers {
                    RequiredModelRow(state: state, asset: CaptionSpeakerTracker.asset)
                }
                Toggle(isOn: $state.speechGapEnabled) {
                    Text("End a sentence on a pause")
                    Text("Most speech has no punctuation, so a pause is what finishes a line for translation.")
                }
                if state.speechGapEnabled {
                    LabeledContent("Pause length") {
                        HStack(spacing: 10) {
                            Slider(value: $state.speechGapHoldMs,
                                   in: Double(SpeechGap.range.lowerBound)...Double(SpeechGap.range.upperBound))
                                .frame(maxWidth: 220)
                            Text(verbatim: CaptionLatencyCopy.pauseLength(milliseconds: state.speechGapHoldMs))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 60, alignment: .trailing)
                        }
                    }
                }
                Picker("Translate with", selection: Binding(
                    get: { translationEngine },
                    set: { state.translationEngine = $0 })) {
                    ForEach(TranslationEngine.userSelectableCases, id: \.self) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .help(translationEngine.summary)
                LabeledContent {
                    Button("Edit…") { showsVocabulary = true }
                } label: {
                    Text("Vocabulary")
                    Text("Names and terms to spell your way.")
                }
                ForEach(HotKeyCenter.Action.allCases, id: \.self) { action in
                    LabeledContent(action.title) {
                        ShortcutRecorder(action: action, state: state)
                    }
                }
                if let e = state.shortcutError {
                    Text(e).foregroundStyle(.orange)
                }
                Toggle(isOn: $state.captionClickThrough) {
                    Text("Let clicks pass through the bubble")
                    Text("Only the top strip can be dragged; the rest clicks through to what is underneath.")
                }
                Toggle(isOn: $state.announceCaptions) {
                    Text("Announce captions to VoiceOver")
                    Text("Each finished sentence is read out, and reaches braille displays.")
                }
                BubbleSurfaceControls(style: $state.style, includePositioning: true)
                LabeledContent("Bubble") {
                    Button("Reset Appearance") { state.style = CaptionStyle() }
                }
                performance
            }
        }
    }

    @ViewBuilder
    private var performance: some View {
        let _ = diagnosticsRevision
        let summaries = Diagnostics.recentTimingSummaries
        if let lag = summaries.first(where: { $0.operation == "captions.visible-lag" }) {
            LabeledContent("Time until a caption appears") {
                Text(verbatim: CaptionPerformanceCopy.duration(lag.p50)).monospacedDigit()
            }
        }
        if let translation = summaries.first(where: { $0.operation == "captions.translation" }) {
            LabeledContent("Translation delay") {
                Text(verbatim: CaptionPerformanceCopy.duration(translation.p50)).monospacedDigit()
            }
        }
        if let rtf = summaries.first(where: { $0.operation == "captions.asr.rtf" }) {
            LabeledContent("Recognition speed") {
                Text(verbatim: CaptionPerformanceCopy.recognitionSpeed(p50RealTimeFactor: rtf.p50))
            }
        }
    }
}
