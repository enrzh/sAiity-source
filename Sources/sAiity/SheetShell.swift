import SwiftUI

/// The frame every sheet shares: title + subtitle, a dismiss button, a divider,
/// and the content.
///
/// This skeleton was copy-pasted per sheet and had already drifted — Done
/// buttons in different places, different paddings, one sheet with an extra
/// header control the others lacked. A change to the chrome now happens once.
struct SheetShell<Content: View, HeaderAccessory: View>: View {
    // LocalizedStringKey, not String: a String parameter binds the literal at
    // the call site to Text's verbatim overload and the sheet header silently
    // stops being translated.
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let width: CGFloat
    let height: CGFloat
    let minimumSize: CGSize?
    let dismissTitle: LocalizedStringKey
    let dismissIsDefaultAction: Bool
    @ViewBuilder var headerAccessory: HeaderAccessory
    @ViewBuilder var content: Content

    @Environment(\.dismiss) private var dismiss

    init(title: LocalizedStringKey, subtitle: LocalizedStringKey,
         width: CGFloat, height: CGFloat,
         minimumSize: CGSize? = nil,
         dismissTitle: LocalizedStringKey = "Done",
         dismissIsDefaultAction: Bool = true,
         @ViewBuilder headerAccessory: () -> HeaderAccessory = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.width = width
        self.height = height
        self.minimumSize = minimumSize
        self.dismissTitle = dismissTitle
        self.dismissIsDefaultAction = dismissIsDefaultAction
        self.headerAccessory = headerAccessory()
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                headerAccessory
                if dismissIsDefaultAction {
                    Button(dismissTitle) { dismiss() }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(dismissTitle) { dismiss() }
                        .buttonStyle(.bordered)
                }
            }
            .padding(14)
            Divider()
            content
        }
        .frame(minWidth: minimumSize?.width ?? width, idealWidth: width,
               maxWidth: minimumSize == nil ? width : .infinity,
               minHeight: minimumSize?.height ?? height, idealHeight: height,
               maxHeight: minimumSize == nil ? height : .infinity)
        .background(.regularMaterial)
        .onExitCommand { dismiss() }
    }
}
