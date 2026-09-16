import SwiftUI

enum RoomTheme {
    private static func color(_ value: UInt32) -> Color {
        Color(red: Double(value >> 16 & 255) / 255, green: Double(value >> 8 & 255) / 255, blue: Double(value & 255) / 255)
    }
    static let paper = color(WebThemeValues.paper)
    static let ink = color(WebThemeValues.ink)
    static let muted = color(WebThemeValues.muted)
    static let sage = color(WebThemeValues.sage)
    static let surface = color(WebThemeValues.surface)
    static let border = color(WebThemeValues.border)
    static let hover = color(WebThemeValues.hover)
    static let fieldSurface = color(WebThemeValues.fieldSurface)
    static let fieldBorder = color(WebThemeValues.fieldBorder)
    static let primary = color(WebThemeValues.primary)
    static let primaryPressed = color(WebThemeValues.primaryPressed)
    static let primaryInk = color(WebThemeValues.primaryInk)
    static let primaryBorder = color(WebThemeValues.primaryBorder)
    static let primaryShadow = color(WebThemeValues.primaryShadow)
    static let error = color(WebThemeValues.error)
    static let errorSoft = color(WebThemeValues.errorSoft)
    static let errorBorder = color(WebThemeValues.errorBorder)
    static let leaf = color(WebThemeValues.leaf)
    static let leafSoft = color(WebThemeValues.leafSoft)
    static let sky = color(WebThemeValues.sky)
    static let skySoft = color(WebThemeValues.skySoft)
    static let surfaceMuted = color(WebThemeValues.surfaceMuted)
    static let radius = WebThemeValues.radius

    static func body(_ size: CGFloat = 16) -> Font {
        .custom("DMSans-9ptRegular_Regular", size: size, relativeTo: .body)
    }
    static func heading(_ size: CGFloat = 26) -> Font {
        .custom("Baloo2-SemiBold", size: size, relativeTo: .title2)
    }
}

struct RoomButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, text }
    var kind = Kind.secondary
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let primary = kind == .primary
        let text = kind == .text
        let foreground = configuration.role == .destructive ? RoomTheme.error
            : primary ? RoomTheme.primaryInk : RoomTheme.ink
        configuration.label
            .font(RoomTheme.body().weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, text ? 0 : 14)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .frame(maxWidth: text ? nil : .infinity)
            .contentShape(Rectangle())
            .background(text ? Color.clear
                : primary ? (configuration.isPressed ? RoomTheme.primaryPressed : RoomTheme.primary)
                : configuration.isPressed ? RoomTheme.hover : RoomTheme.surface,
                in: RoundedRectangle(cornerRadius: RoomTheme.radius))
            .overlay(RoundedRectangle(cornerRadius: RoomTheme.radius)
                .stroke(text ? Color.clear : primary ? RoomTheme.primaryBorder : RoomTheme.border, lineWidth: 1))
            .compositingGroup()
            .shadow(color: text ? .clear : primary ? RoomTheme.primaryShadow : RoomTheme.ink.opacity(0.1),
                    radius: 0, y: configuration.isPressed ? 0 : primary ? 3 : 2)
            .opacity(enabled ? 1 : 0.5)
    }
}

struct RoomFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(RoomTheme.body())
            .foregroundStyle(RoomTheme.ink)
            .padding(12)
            .frame(minHeight: 44)
            .background(RoomTheme.fieldSurface, in: RoundedRectangle(cornerRadius: RoomTheme.radius))
            .overlay(RoundedRectangle(cornerRadius: RoomTheme.radius).stroke(RoomTheme.fieldBorder, lineWidth: 1))
    }
}

struct RoomField: View {
    let label: String
    @Binding var text: String
    var secure = false
    var axis = Axis.horizontal

    init(_ label: String, text: Binding<String>, secure: Bool = false, axis: Axis = .horizontal) {
        self.label = label
        _text = text
        self.secure = secure
        self.axis = axis
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
            if secure {
                SecureField("", text: $text)
                    .accessibilityLabel(label)
                    .accessibilityIdentifier(label)
            } else {
                TextField("", text: $text, axis: axis)
                    .accessibilityLabel(label)
                    .accessibilityIdentifier(label)
            }
        }
    }
}

struct AccountSection<Content: View, Footer: View>: View {
    let title: String?
    let content: Content
    let footer: Footer

    init(_ title: String? = nil, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title { Text(title).font(RoomTheme.heading(20)) }
            content
            footer.font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension AccountSection where Footer == EmptyView {
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, content: content, footer: { EmptyView() })
    }
}

struct RoomSheetPresentation: ViewModifier {
    let idealHeight: CGFloat

    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            content.frame(idealWidth: 560, idealHeight: idealHeight).presentationSizing(.fitted)
        } else {
            content.presentationDetents([.large]).presentationDragIndicator(.visible)
        }
    }
}
