import SwiftUI

/// Uses the shared web error treatment for both banners and field errors.
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
