import SwiftUI

/// Mirrors the web `Feedback` component and its `.feedback.feedback-error` rule: one error
/// treatment everywhere, a solid `--red-dark` fill with `--control-surface` text, an alert
/// icon and optional actions. The web uses the same block for banners and field errors, so
/// this does too rather than inventing a quieter inline variant.
struct RoomFeedback<Actions: View>: View {
    private let message: String
    private let identifier: String?
    private let actions: Actions

    init(_ message: String, identifier: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.message = message
        self.identifier = identifier
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .center, spacing: RoomFeedbackMetrics.gap) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: RoomFeedbackMetrics.icon))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: RoomFeedbackMetrics.gap) {
                Text(message)
                    .font(RoomTheme.body(RoomFeedbackMetrics.text))
                    .lineSpacing(RoomFeedbackMetrics.lineSpacing)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier(identifier ?? "")
                actions
            }
        }
        .padding(RoomFeedbackMetrics.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(RoomTheme.surface)
        .background(RoomTheme.errorFill, in: RoundedRectangle(cornerRadius: RoomTheme.radius))
        .accessibilityElement(children: .contain)
    }
}

extension RoomFeedback where Actions == EmptyView {
    init(_ message: String, identifier: String? = nil) {
        self.init(message, identifier: identifier) { EmptyView() }
    }
}

enum RoomFeedbackMetrics {
    /// 0.75rem padding, 0.625rem gap, 1.125rem icon and max(12px, 0.75rem) text from the
    /// shared `.feedback` rule, with its 1.6 line height expressed as extra leading.
    static let padding: CGFloat = 12
    static let gap: CGFloat = 10
    static let icon: CGFloat = 18
    static let text: CGFloat = 12
    static let lineSpacing: CGFloat = text * 1.6 - text
}

/// The web renders feedback actions as small secondary buttons inside the block, which on the
/// solid error fill means an outlined control rather than the room's default green button.
struct RoomFeedbackActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(RoomTheme.body(RoomFeedbackMetrics.text).weight(.semibold))
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .foregroundStyle(RoomTheme.surface)
            .background(RoomTheme.surface.opacity(configuration.isPressed ? 0.28 : 0.16),
                        in: RoundedRectangle(cornerRadius: RoomTheme.radius))
            .overlay(RoundedRectangle(cornerRadius: RoomTheme.radius).stroke(RoomTheme.surface.opacity(0.45)))
    }
}
