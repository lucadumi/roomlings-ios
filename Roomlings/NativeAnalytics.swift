import Foundation
import OSLog
import RoomlingsCore

private let analyticsLog = Logger(subsystem: "com.roomlings.app", category: "Analytics")

@MainActor
final class NativeAnalytics {
    enum Failure: String {
        case invalidContext, contextChanged, invalidEvent, capacity, cancelled, delivery
    }

    private(set) var context: AnalyticsContext?
    private let client: AccountSession
    private let now: () -> Date
    private let timeZone: () -> TimeZone
    private let report: (Failure) -> Void
    private var foregroundAt: Date?
    private var openedContexts: Set<AnalyticsContext> = []
    private var pending: [UUID: Task<Void, Never>] = [:]

    init(
        client: AccountSession, now: @escaping () -> Date = Date.init,
        timeZone: @escaping () -> TimeZone = { .current },
        report: @escaping (Failure) -> Void = {
            analyticsLog.error("Native analytics was not confirmed (\($0.rawValue, privacy: .public)); no automatic retry.")
        }
    ) {
        self.client = client
        self.now = now
        self.timeZone = timeZone
        self.report = report
    }

    func updateAccount(_ state: AccountState?) {
        let next: AnalyticsContext?
        if let state, state.isSignedIn, !state.deletionPending, state.session != nil {
            do {
                next = try AnalyticsContext(state: state)
            } catch {
                setContext(nil)
                report(.invalidContext)
                return
            }
        } else {
            next = nil
        }
        setContext(next)
        recordForegroundIfReady()
    }

    func becameActive() {
        guard foregroundAt == nil else { return }
        foregroundAt = now()
        openedContexts.removeAll()
        recordForegroundIfReady()
    }

    func enteredBackground() {
        foregroundAt = nil
        openedContexts.removeAll()
    }

    @discardableResult
    func record(
        _ kind: AnalyticsEventKind, context expected: AnalyticsContext, at date: Date? = nil
    ) -> Task<Void, Never>? {
        guard context == expected else {
            report(.contextChanged)
            return nil
        }
        guard pending.count < 50 else {
            report(.capacity)
            return nil
        }
        let event: AnalyticsEvent
        do {
            event = try AnalyticsEvent(kind: kind, at: date ?? now(), timeZone: timeZone())
        } catch {
            report(.invalidEvent)
            return nil
        }
        let id = UUID()
        let task = Task { [weak self, client, report] in
            do {
                try await client.recordAnalytics(event, context: expected)
            } catch is CancellationError {
                report(.cancelled)
            } catch {
                report(.delivery)
            }
            self?.pending.removeValue(forKey: id)
        }
        pending[id] = task
        return task
    }

    private func setContext(_ next: AnalyticsContext?) {
        guard next != context else { return }
        for task in pending.values { task.cancel() }
        pending.removeAll()
        if context?.accountID != next?.accountID || context?.deviceID != next?.deviceID {
            openedContexts.removeAll()
        }
        context = next
    }

    private func recordForegroundIfReady() {
        guard let foregroundAt, let context, openedContexts.insert(context).inserted else { return }
        record(.appOpened, context: context, at: foregroundAt)
    }
}
