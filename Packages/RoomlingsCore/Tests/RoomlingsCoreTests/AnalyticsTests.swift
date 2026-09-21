import Foundation
import Testing
@testable import RoomlingsCore

@Suite("Native retention events", .timeLimit(.minutes(1)))
struct AnalyticsTests {
    private let instant = AccountValidation.instant("2026-09-20T00:30:00.000Z")!

    @Test(arguments: AnalyticsEventKind.allCases)
    func sendsOnlyTheAllowlistedEventUnderTheAuthenticatedMember(kind: AnalyticsEventKind) async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(Fixtures.state(selectedHousehold: true)),
            try Fixtures.response(["recorded": .integer(1)])
        ])
        let credentials = MemoryTokenStore(token: Fixtures.oldToken)
        let session = makeSession(transport, credentials)
        let original = try await session.restore()
        let context = try AnalyticsContext(state: original)
        let event = try AnalyticsEvent(kind: kind, at: instant, timeZone: #require(TimeZone(secondsFromGMT: -43_200)))
        try await session.recordAnalytics(event, context: context)
        let request = try #require(await transport.requests.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/account/households/\(Fixtures.householdID)/analytics")
        #expect(request.url?.query == nil)
        #expect(request.value(forHTTPHeaderField: "X-Roomlings-Client") == "ios")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let authenticated = request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Fixtures.oldToken.value)"
        #expect(authenticated)
        #expect(!request.httpShouldHandleCookies)
        for header in ["Origin", "Cookie", "X-CSRF-Token", "Sec-Fetch-Site"] {
            #expect(request.value(forHTTPHeaderField: header) == nil)
        }
        let body = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
        #expect(body == .object(["events": .array([.object([
            "kind": .string(kind.rawValue), "occurredAt": .string("2026-09-20T00:30:00.000Z"),
            "localDate": .string("2026-09-19")
        ])])]))
        #expect(await session.state == original)
        #expect(await session.isBusy == false)
        #expect(await credentials.token == Fixtures.oldToken)
        #expect(await credentials.clearAttempts == 0)
        #expect(await credentials.saveAttempts == 0)
    }

    @Test
    func localDatesUseTheOccurrenceTimeZoneAndNeverTheUsersCalendar() throws {
        let behind = try AnalyticsEvent(kind: .appOpened, at: instant, timeZone: #require(TimeZone(secondsFromGMT: -43_200)))
        let ahead = try AnalyticsEvent(
            kind: .appOpened, at: instant.addingTimeInterval(16 * 3600),
            timeZone: #require(TimeZone(secondsFromGMT: 50_400))
        )
        #expect(behind.localDate == "2026-09-19")
        #expect(ahead.localDate == "2026-09-21")
        #expect(ahead.occurredAt == "2026-09-20T16:30:00.000Z")
        for invalid in [Double.infinity, -Double.infinity, Double.nan, 1e100] {
            #expect(throws: AccountError.invalidInput(.date)) {
                try AnalyticsEvent(kind: .appOpened, at: Date(timeIntervalSince1970: invalid))
            }
        }
    }

    @Test(arguments: [
        [:], ["recorded": JSONValue.integer(0)], ["recorded": .integer(2)], ["recorded": .integer(-1)],
        ["recorded": .string("1")], ["recorded": .bool(true)], ["recorded": .null],
        ["recorded": .integer(1), "accessToken": .string("unexpected")]
    ])
    func onlyAnExactSingleEventAcknowledgmentCountsAsSuccess(fields: [String: JSONValue]) async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(Fixtures.state(selectedHousehold: true)), try Fixtures.response(fields)
        ])
        let session = makeSession(transport)
        let context = try AnalyticsContext(state: await session.restore())
        await #expect(throws: AccountError.invalidResponse) {
            try await session.recordAnalytics(event(), context: context)
        }
        #expect(await transport.requests.count == 2)
    }

    @Test(arguments: [400, 401, 403, 404, 409, 429, 500, 503])
    func failedTelemetryIsNeverRetriedAndNeverInvalidatesTheAccount(status: Int) async throws {
        let transport = TestTransport(responses: [
            try Fixtures.response(Fixtures.state(selectedHousehold: true)),
            try Fixtures.failure(status: status, code: status == 401 ? "ACCOUNT_SESSION_REQUIRED" : nil)
        ])
        let credentials = MemoryTokenStore(token: Fixtures.oldToken)
        let session = makeSession(transport, credentials)
        let original = try await session.restore()
        await #expect(throws: AccountError.server(status: status, code: status == 401 ? .accountSessionRequired : nil)) {
            try await session.recordAnalytics(event(), context: AnalyticsContext(state: original))
        }
        #expect(await transport.requests.count == 2)
        #expect(await session.state == original)
        #expect(await credentials.token == Fixtures.oldToken)
        #expect(await credentials.clearAttempts == 0)
        #expect(await credentials.saveAttempts == 0)
        #expect(await session.isBusy == false)
    }

    @Test(arguments: [
        "unrestored", "signed-out", "unselected", "deleting", "inactive",
        "different-device", "different-account", "different-household", "different-member"
    ])
    func attributionRequiresTheSameActiveAccountDeviceAndMember(kind: String) async throws {
        let original = try JSONDecoder().decode(AccountState.self, from: Fixtures.data(Fixtures.state(selectedHousehold: true)))
        let context = try AnalyticsContext(state: original)
        var fields = Fixtures.state(
            signedIn: kind != "signed-out",
            selectedHousehold: !["unselected", "signed-out", "deleting"].contains(kind),
            deletionPending: kind == "deleting"
        )
        if kind == "inactive" { fields = try NotificationFixtures.inactiveState() }
        if kind == "different-device", case .object(var device) = Fixtures.device {
            device["id"] = .string(UUID().uuidString)
            fields["devices"] = .array([.object(device)])
        }
        if kind == "different-account", case .object(var account) = Fixtures.account {
            account["id"] = .string(UUID().uuidString)
            fields["account"] = .object(account)
        }
        if ["different-household", "different-member"].contains(kind),
           case .object(var household) = Fixtures.household, case .object(var membership) = Fixtures.membership {
            let replacement = UUID().uuidString
            if kind == "different-household" {
                household["id"] = .string(replacement)
                membership["householdId"] = .string(replacement)
            } else {
                household["members"] = .array([.object([
                    "id": .string(replacement), "name": .string("Roommate"), "color": .string("#7d9070")
                ])])
                membership["memberId"] = .string(replacement)
            }
            fields["memberships"] = .array([.object(membership)])
            fields["session"] = .object([
                "token": .null, "memberId": membership["memberId"]!, "household": .object(household)
            ])
        }
        let transport = TestTransport(response: try Fixtures.response(fields))
        let session = makeSession(transport)
        if kind != "unrestored" { try await session.restore() }
        let before = await session.state
        await #expect(throws: AccountError.accountStateRequired) {
            try await session.recordAnalytics(event(), context: context)
        }
        #expect(await transport.requests.count == (kind == "unrestored" ? 0 : 1))
        #expect(await session.state == before)
    }

    @Test(arguments: ["missing", "changed", "read-failed"])
    func credentialFailuresNeverFallBackToAnotherIdentity(kind: String) async throws {
        let transport = TestTransport(response: try Fixtures.response(Fixtures.state(selectedHousehold: true)))
        let credentials = MemoryTokenStore(token: Fixtures.oldToken)
        let session = makeSession(transport, credentials)
        let original = try await session.restore()
        if kind == "read-failed" {
            await credentials.setReadFailure(SensitiveFailure(detail: "private storage detail"))
        } else {
            await credentials.replaceToken(kind == "missing" ? nil : Fixtures.newToken)
        }
        await #expect(throws: kind == "read-failed" ? AccountError.credentialStorage : .accountStateRequired) {
            try await session.recordAnalytics(event(), context: AnalyticsContext(state: original))
        }
        #expect(await transport.requests.count == 1)
        #expect(await credentials.clearAttempts == 0)
        #expect(await credentials.saveAttempts == 0)
        #expect(await session.state == original)
    }

    @Test
    func anInFlightAnalyticsFailureCannotBlockLogoutOrEraseNewCredentials() async throws {
        let started = Signal()
        let finish = Signal()
        let transport = TestTransport { request, _ in
            if request.url?.path.hasSuffix("/analytics") == true {
                await started.signal()
                await finish.wait()
                return try Fixtures.failure(status: 401, code: "ACCOUNT_SESSION_REQUIRED")
            }
            if request.url?.path.hasSuffix("/logout") == true {
                return try Fixtures.response(Fixtures.state(signedIn: false))
            }
            if request.url?.path.hasSuffix("/verify") == true {
                return try Fixtures.response(Fixtures.state(token: Fixtures.newToken, selectedHousehold: true))
            }
            return try Fixtures.response(Fixtures.state(selectedHousehold: true))
        }
        let credentials = MemoryTokenStore(token: Fixtures.oldToken)
        let session = makeSession(transport, credentials)
        let context = try AnalyticsContext(state: await session.restore())
        let event = try event()
        let task = Task { try await session.recordAnalytics(event, context: context) }
        await started.wait()
        #expect(await session.isBusy == false)
        try await session.logout()
        let fresh = try await session.verifyEmailCode(
            email: "roommate@example.com", code: "123456", name: "Roommate", deviceLabel: "iPhone"
        )
        await finish.signal()
        await #expect(throws: AccountError.server(status: 401, code: .accountSessionRequired)) { try await task.value }
        #expect(await session.state == fresh)
        #expect(await credentials.token == Fixtures.newToken)
        #expect(await credentials.clearAttempts == 1)
        #expect(await credentials.saveAttempts == 1)
    }

    @Test
    func cancellationCannotReportALateAcknowledgmentAsSuccess() async throws {
        let started = Signal()
        let finish = Signal()
        let transport = TestTransport { request, _ in
            if request.url?.path.hasSuffix("/analytics") == true {
                await started.signal()
                await finish.wait()
                return try Fixtures.response(["recorded": .integer(1)])
            }
            return try Fixtures.response(Fixtures.state(selectedHousehold: true))
        }
        let session = makeSession(transport)
        let original = try await session.restore()
        let context = try AnalyticsContext(state: original)
        let event = try event()
        let task = Task { try await session.recordAnalytics(event, context: context) }
        await started.wait()
        task.cancel()
        await finish.signal()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await session.state == original)
        #expect(await session.isBusy == false)
    }

    @Test
    func anAnalyticsAcknowledgmentCannotRollBackAConcurrentHouseholdRefresh() async throws {
        let started = Signal()
        let finish = Signal()
        var changed = Fixtures.state(selectedHousehold: true)
        var household = try HouseholdFields(Fixtures.household).object
        household["version"] = .integer(18)
        changed["session"] = .object([
            "token": .null, "memberId": .string(Fixtures.memberID), "household": .object(household)
        ])
        let refreshed = try Fixtures.response(changed)
        let transport = TestTransport { request, index in
            if request.url?.path.hasSuffix("/analytics") == true {
                await started.signal()
                await finish.wait()
                return try Fixtures.response(["recorded": .integer(1)])
            }
            return index == 0 ? try Fixtures.response(Fixtures.state(selectedHousehold: true)) : refreshed
        }
        let session = makeSession(transport)
        let context = try AnalyticsContext(state: await session.restore())
        let event = try event()
        let pending = Task { try await session.recordAnalytics(event, context: context) }
        await started.wait()
        let latest = try await session.restore()
        await finish.signal()
        try await pending.value
        #expect(await session.state == latest)
        #expect(await session.selectedHousehold?.version == 18)
    }

    private func event() throws -> AnalyticsEvent {
        try AnalyticsEvent(kind: .appOpened, at: instant, timeZone: #require(TimeZone(secondsFromGMT: 0)))
    }

    private func makeSession(_ transport: TestTransport, _ credentials: MemoryTokenStore? = nil) -> AccountSession {
        AccountSession(configuration: Fixtures.configuration,
                       tokenStore: credentials ?? MemoryTokenStore(token: Fixtures.oldToken), transport: transport)
    }
}
