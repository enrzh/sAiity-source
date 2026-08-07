import SwiftUI

/// The frame every picker sheet shares: title + subtitle, trailing buttons with
/// Done last, a divider, the content.
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
    @ViewBuilder var headerAccessory: HeaderAccessory
    @ViewBuilder var content: Content

    @Environment(\.dismiss) private var dismiss

    init(title: LocalizedStringKey, subtitle: LocalizedStringKey,
         width: CGFloat, height: CGFloat,
         @ViewBuilder headerAccessory: () -> HeaderAccessory = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.width = width
        self.height = height
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
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()
            content
        }
        .frame(width: width, height: height)
    }
}
