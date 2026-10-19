import AppKit
import SwiftUI

// MARK: - Permissions

/// Live permission state for a settings page or the setup window.
///
/// macOS posts no notification when a privacy switch changes, and the user
/// flips it in another app. Polling once a second while a page is visible is
/// the only way the row can turn to "Allowed" while they are still looking.
@MainActor
@Observable
final class PermissionMonitor {
    private(set) var statuses: [AppPermission: AppPermission.Status] = [:]

    func status(_ permission: AppPermission) -> AppPermission.Status {
        statuses[permission] ?? permission.status
    }

    func refresh() {
        for permission in AppPermission.allCases {
            let value = permission.status
            if statuses[permission] != value { statuses[permission] = value }
        }
    }

    /// Runs for as long as the calling view's task does.
    func watch() async {
        while !Task.isCancelled {
            refresh()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    func missing(for feature: AppPermission.Feature) -> [AppPermission] {
        AppPermission.allCases.filter { $0.feature == feature && status($0) != .granted }
    }
}

/// One permission as a form row: name and purpose on the left, its state or
/// the one action that changes it on the right.
struct PermissionRow: View {
    let permission: AppPermission
    let status: AppPermission.Status

    var body: some View {
        LabeledContent {
            switch status {
            case .granted:
                Text("Allowed")
                    .foregroundStyle(.secondary)
            case .notAsked:
                Button("Allow…") { permission.request() }
            case .off:
                Button("Open Settings…") { permission.request() }
            }
        } label: {
            Text(verbatim: permission.title)
            Text(verbatim: permission.purpose)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Translation target

/// "Translate to" as one menu: Off, the languages used recently, and the full
/// searchable list. The old row was a button, a second Off button and a
/// separate on/off checkbox for the same decision.
struct TranslationTargetRow: View {
    let title: LocalizedStringKey
    @Binding var target: String?
    let recent: [String]
    let showAll: () -> Void

    private static let more = "__more__"

    private var selection: Binding<String> {
        Binding(
            get: { target ?? "" },
            set: { value in
                if value == Self.more {
                    showAll()
                } else {
                    target = value.isEmpty ? nil : value
                }
            })
    }

    private var choices: [String] {
        var codes = recent
        if let target, !codes.contains(target) { codes.insert(target, at: 0) }
        return codes
    }

    var body: some View {
        Picker(title, selection: selection) {
            Text("Off").tag("")
            Divider()
            ForEach(choices, id: \.self) { code in
                Text(verbatim: AppLanguage(code: code).displayName).tag(code)
            }
            Divider()
            Text("Other Language…").tag(Self.more)
        }
    }
}

/// A model the current choice depends on but that is not on this Mac yet, as
/// a row with its download control. Empty when everything is in place.
struct RequiredModelRow: View {
    @Bindable var state: AppState
    let asset: ModelAsset

    var body: some View {
        let status = state.assets.first(where: { $0.id == asset.id }) ?? ModelRegistry.status(of: asset)
        if state.needsModelRepair(status) {
            LabeledContent {
                AssetControl(state: state, status: status)
            } label: {
                Text(verbatim: asset.title)
                if !status.isInstalled, let bytes = asset.advertisedBytes {
                    Text("Needs a download of \(ModelRegistry.format(bytes)).")
                }
            }
        }
    }
}

// MARK: - Bubble appearance

/// The bubble's look as one menu. The preview cards it replaces drew sample
/// words in boxes too narrow to hold them, so they broke mid-word.
struct BubbleStylePicker: View {
    @Binding var style: CaptionStyle
    let context: BubbleStyleContext

    private var selection: Binding<String> {
        Binding(
            get: { style.matchingPreset(for: context)?.rawValue ?? "" },
            set: { raw in
                guard let preset = BubbleStylePreset(rawValue: raw) else { return }
                style = preset.applying(to: style, context: context)
            })
    }

    var body: some View {
        Picker("Style", selection: selection) {
            ForEach(BubbleStylePreset.allCases, id: \.self) { preset in
                Text(verbatim: preset.title).tag(preset.rawValue)
            }
            if style.matchingPreset(for: context) == nil {
                Divider()
                Text("Custom").tag("")
            }
        }
    }
}

/// Text size for both lines of a bubble, which always change together.
struct BubbleTextSizeSlider: View {
    @Binding var style: CaptionStyle
    let context: BubbleStyleContext

    private var range: ClosedRange<Double> {
        context == .dictation ? 10...28 : 16...54
    }

    private var size: Binding<Double> {
        Binding(
            get: { style.original.fontSize },
            set: { value in
                var updated = style
                updated.original.fontSize = value.rounded()
                updated.translation.fontSize = value.rounded()
                style = updated
            })
    }

    var body: some View {
        LabeledContent("Text size") {
            HStack(spacing: 10) {
                Slider(value: size, in: range)
                    .frame(maxWidth: 220)
                Text("\(Int(style.original.fontSize.rounded())) pt")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }
}

// MARK: - Confirmation

/// Deleting a model is a multi-hundred-megabyte download to undo, so the
/// settings pages ask first. AssetControl itself stays immediate for the
/// places that already confirm.
enum ModelDeletion {
    @MainActor
    static func confirm(_ asset: ModelAsset, size: Int64) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete \(asset.title)?")
        alert.informativeText = size > 0
            ? String(localized: "This frees \(ModelRegistry.format(size)). You can download it again later.")
            : String(localized: "You can download it again later.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
