import SwiftUI
import UIKit

struct InvitationShareSheet: UIViewControllerRepresentable {
    let link: URL
    let subject: String
    let onCompletion: @MainActor (Bool, Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: [InvitationActivityItem(link: link, subject: subject)], applicationActivities: nil
        )
        let coordinator = context.coordinator
        controller.completionWithItemsHandler = { _, completed, _, error in
            let failed = error != nil
            Task { @MainActor in coordinator.finish(completed: completed, failed: failed) }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCompletion: onCompletion) }

    @MainActor
    final class Coordinator {
        private var finished = false
        private let onCompletion: (Bool, Bool) -> Void

        init(onCompletion: @escaping (Bool, Bool) -> Void) { self.onCompletion = onCompletion }

        func finish(completed: Bool, failed: Bool) {
            guard !finished else { return }
            finished = true
            onCompletion(completed, failed)
        }
    }
}

private final class InvitationActivityItem: NSObject, UIActivityItemSource {
    private let link: URL
    private let subject: String

    init(link: URL, subject: String) {
        self.link = link
        self.subject = subject
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { link }

    func activityViewController(
        _ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? { link }

    func activityViewController(
        _ activityViewController: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?
    ) -> String { subject }
}
