import XCTest
import RoomlingsCore
@testable import Roomlings

@MainActor
final class AnalyticsModelTests: XCTestCase {
    private let fixture = InvitationModelFixture()

    func testForegroundWaitsForASelectedHouseholdAndRefreshDoesNotCountAnotherOpen() async throws {
        let setup = try make([
            fixture.state(selectedHousehold: false), fixture.state(), fixture.state()
        ])
        setup.model.analyticsBecameActive()
        await setup.model.start()
        let empty = await setup.transport.events
        XCTAssertTrue(empty.isEmpty)
        let selected = await setup.model.refresh()
        XCTAssertTrue(selected)
        try await waitForEvents(1, setup.transport)
        setup.model.analyticsBecameActive()
        let refreshed = await setup.model.refresh()
        XCTAssertTrue(refreshed)
        let events = await setup.transport.events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, "app_opened")
        XCTAssertEqual(setup.model.headerStatus, .loaded)
    }

    func testAWeekOfForegroundVisitsKeepsEachOriginalLocalDay() async throws {
        let clock = AnalyticsClock()
        let setup = try make([fixture.state()], now: { clock.date })
        await setup.model.start()
        for day in 0...7 {
            clock.date = clock.start.addingTimeInterval(Double(day) * 86_400)
            setup.model.analyticsBecameActive()
            try await waitForEvents(day + 1, setup.transport)
            setup.model.analyticsEnteredBackground()
        }
        let events = await setup.transport.events
        XCTAssertEqual(events.map(\.localDate), (20...27).map { "2026-09-\($0)" })
        XCTAssertTrue(events.allSatisfy { $0.kind == "app_opened" })
        XCTAssertEqual(Set(events.map(\.householdID)), [fixture.householdID.uuidString.lowercased()])
    }

    func testEachSelectedHouseholdIsCountedOnlyOnceInTheSameForegroundVisit() async throws {
        let setup = try make([
            fixture.state(), fixture.state(householdID: fixture.otherHouseholdID), fixture.state()
        ])
        await setup.model.start()
        setup.model.analyticsBecameActive()
        try await waitForEvents(1, setup.transport)
        let switched = await setup.model.select(id: fixture.otherHouseholdID)
        XCTAssertTrue(switched)
        try await waitForEvents(2, setup.transport)
        let returned = await setup.model.select(id: fixture.householdID)
        XCTAssertTrue(returned)
        let events = await setup.transport.events
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(Set(events.map(\.householdID)), [
            fixture.householdID.uuidString.lowercased(), fixture.otherHouseholdID.uuidString.lowercased()
        ])
    }

    func testTelemetryFailureLeavesTheAccountUsableAndDoesNotRetryOnRefresh() async throws {
        let diagnostics = AnalyticsDiagnostics()
        let setup = try make([fixture.state(), fixture.state()], status: 503, report: { diagnostics.failures.append($0) })
        await setup.model.start()
        setup.model.analyticsBecameActive()
        let reported = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in MainActor.assumeIsolated { !diagnostics.failures.isEmpty } }, object: nil
        )
        await fulfillment(of: [reported], timeout: 5)
        XCTAssertEqual(diagnostics.failures, [.delivery])
        XCTAssertNil(setup.model.message)
        XCTAssertEqual(setup.model.headerStatus, .loaded)
        XCTAssertFalse(setup.model.busy)
        let refreshed = await setup.model.refresh()
        XCTAssertTrue(refreshed)
        let events = await setup.transport.events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(setup.model.headerStatus, .loaded)
    }

    func testOnlyCompletedSharingIsCountedAndSystemCompletionIsHandledOnce() async throws {
        let setup = try make([fixture.state()])
        await setup.model.start()
        let context = try XCTUnwrap(setup.model.analyticsContext)
        let cancelled = InvitationShareSheet.Coordinator { completed, failed in
            setup.model.invitationSharingFinished(context: context, completed: completed, failed: failed)
        }
        cancelled.finish(completed: false, failed: false)
        let failed = InvitationShareSheet.Coordinator { completed, failed in
            setup.model.invitationSharingFinished(context: context, completed: completed, failed: failed)
        }
        failed.finish(completed: true, failed: true)
        XCTAssertNotNil(setup.model.message)
        let before = await setup.transport.events
        XCTAssertTrue(before.isEmpty)
        setup.model.clearFeedback()
        let completed = InvitationShareSheet.Coordinator { completed, failed in
            setup.model.invitationSharingFinished(context: context, completed: completed, failed: failed)
        }
        completed.finish(completed: true, failed: false)
        completed.finish(completed: true, failed: false)
        try await waitForEvents(1, setup.transport)
        let events = await setup.transport.events
        XCTAssertEqual(events.map(\.kind), ["invite_shared"])
        XCTAssertNil(setup.model.message)
    }

    func testConfirmedNewMembershipCountsOnceAndFailedOrRepeatedJoinsDoNot() async throws {
        let setup = try make([
            fixture.state(selectedHousehold: false), fixture.failure(409), fixture.state(), fixture.state()
        ])
        await setup.model.start()
        let failed = await setup.model.join(code: fixture.code, memberName: "Ada")
        XCTAssertFalse(failed)
        let before = await setup.transport.events
        XCTAssertTrue(before.isEmpty)
        let joined = await setup.model.join(code: fixture.code, memberName: "Sam")
        XCTAssertTrue(joined)
        try await waitForEvents(1, setup.transport)
        let repeated = await setup.model.join(code: fixture.code, memberName: "Sam")
        XCTAssertTrue(repeated)
        let events = await setup.transport.events
        XCTAssertEqual(events.map(\.kind), ["invite_accepted"])
    }

    func testOldShareContextsCannotFollowAHouseholdSwitch() async throws {
        let diagnostics = AnalyticsDiagnostics()
        let setup = try make(
            [fixture.state(), fixture.state(householdID: fixture.otherHouseholdID)],
            report: { diagnostics.failures.append($0) }
        )
        await setup.model.start()
        let original = try XCTUnwrap(setup.model.analyticsContext)
        let switched = await setup.model.select(id: fixture.otherHouseholdID)
        XCTAssertTrue(switched)
        setup.model.invitationSharingFinished(context: original, completed: true, failed: false)
        let events = await setup.transport.events
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(diagnostics.failures, [.contextChanged])
    }

    func testASlowAnalyticsRequestDoesNotBlockSignOutAndCannotKeepItsContext() async throws {
        let setup = try make([fixture.state(), fixture.state(signedIn: false)], hold: true)
        await setup.model.start()
        let context = try XCTUnwrap(setup.model.analyticsContext)
        let delivery = try XCTUnwrap(setup.analytics.record(.appOpened, context: context))
        try await waitForEvents(1, setup.transport)
        XCTAssertFalse(setup.model.busy)
        let signedOut = await setup.model.signOut()
        XCTAssertTrue(signedOut)
        XCTAssertNil(setup.model.analyticsContext)
        await setup.transport.release.signal()
        await delivery.value
        XCTAssertFalse(setup.model.signedIn)
        XCTAssertNil(setup.model.message)
    }

    func testInFlightEventsAreBoundedWithoutHoldingTheAccountGate() async throws {
        let diagnostics = AnalyticsDiagnostics()
        let setup = try make([fixture.state()], hold: true, report: { diagnostics.failures.append($0) })
        await setup.model.start()
        let context = try XCTUnwrap(setup.model.analyticsContext)
        let tasks = (0..<51).compactMap { _ in setup.analytics.record(.inviteShared, context: context) }
        XCTAssertEqual(tasks.count, 50)
        XCTAssertEqual(diagnostics.failures, [.capacity])
        XCTAssertFalse(setup.model.busy)
        await setup.transport.release.signal()
        for task in tasks { await task.value }
        let events = await setup.transport.events
        XCTAssertEqual(events.count, 50)
    }

    private func make(
        _ responses: [HTTPResponse], status: Int = 200, hold: Bool = false,
        now: @escaping () -> Date = { Date(timeIntervalSince1970: 1_789_934_400) },
        report: @escaping (NativeAnalytics.Failure) -> Void = { _ in }
    ) throws -> (model: AccountModel, analytics: NativeAnalytics, transport: AnalyticsModelTransport) {
        let transport = AnalyticsModelTransport(responses: responses, status: status, hold: hold)
        let store = InvitationModelStore(token: try SessionToken(String(repeating: "a", count: 43)))
        let client = AccountSession(configuration: fixture.api, tokenStore: store, transport: transport)
        let analytics = NativeAnalytics(client: client, now: now, timeZone: { TimeZone(secondsFromGMT: 0)! }, report: report)
        return (AccountModel(client: client, invitationOrigin: fixture.origin, analytics: analytics), analytics, transport)
    }

    private func waitForEvents(_ count: Int, _ transport: AnalyticsModelTransport) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if await transport.events.count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The native analytics request did not arrive.")
    }
}

@MainActor
private final class AnalyticsClock {
    let start = ISO8601DateFormatter().date(from: "2026-09-20T12:00:00Z")!
    lazy var date = start
}

@MainActor
private final class AnalyticsDiagnostics {
    var failures: [NativeAnalytics.Failure] = []
}

private actor AnalyticsModelTransport: HTTPTransport {
    struct Event {
        let kind: String
        let localDate: String
        let householdID: String
    }

    let release = InvitationModelSignal()
    private(set) var events: [Event] = []
    private var responses: [HTTPResponse]
    private let status: Int
    private let hold: Bool

    init(responses: [HTTPResponse], status: Int, hold: Bool) {
        self.responses = responses
        self.status = status
        self.hold = hold
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        if let url = request.url, url.path.hasSuffix("/analytics") {
            let data = try XCTUnwrap(request.httpBody)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [[String: String]]])
            let event = try XCTUnwrap(body["events"]?.first)
            events.append(Event(kind: try XCTUnwrap(event["kind"]), localDate: try XCTUnwrap(event["localDate"]),
                                householdID: url.deletingLastPathComponent().lastPathComponent))
            if hold { await release.wait() }
            return HTTPResponse(data: Data("{\"recorded\":1}".utf8), statusCode: status, url: url)
        }
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return responses.removeFirst()
    }
}
