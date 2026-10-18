import Foundation
import Testing
@testable import RoomlingsCore

@Suite("Notification inbox", .timeLimit(.minutes(1)))
struct InboxTests {
    private let me = UUID(uuidString: Fixtures.memberID)!

    /// Every rule `inboxItems` applies: turns, rotations past former roommates, archived, upcoming and
    /// other roommates' chores, money you share but did not pay, the 30-day window and bill names.
    private static let household = #"""
{"id":"11111111-1111-4111-8111-111111111111","name":"Our kitchen","currency":"EUR","budget":45000,"version":17,"inviteCode":"test-only-invite","billingTimeZone":"UTC",
"members":[{"id":"22222222-2222-4222-8222-222222222222","name":"Ada","color":"#7d9070"},{"id":"55555555-5555-4555-8555-555555555555","name":"Sam","color":"#c9533a"},{"id":"66666666-6666-4666-8666-666666666666","name":"Former","color":"#7c89a1","inactive":true}],
"chores":{"history":[],"items":[
{"id":"a1111111-1111-4111-8111-111111111111","title":"Clear the sink","notes":"","roomId":"kitchen","area":"sink","componentId":"default-kitchen-sink","componentName":"Sink","dueDate":"2026-10-14","repeatDays":7,"rotation":["22222222-2222-4222-8222-222222222222"],"turn":0,"createdBy":"22222222-2222-4222-8222-222222222222","createdAt":"2026-09-01T12:00:00.000Z","updatedAt":"2026-09-01T12:00:00.000Z","version":1,"occurrence":0,"archived":false},
{"id":"a2222222-2222-4222-8222-222222222222","title":"Take out recycling","notes":"","roomId":null,"area":null,"dueDate":"2026-10-17","repeatDays":null,"rotation":["66666666-6666-4666-8666-666666666666","22222222-2222-4222-8222-222222222222"],"turn":0,"createdBy":"22222222-2222-4222-8222-222222222222","createdAt":"2026-09-01T12:00:00.000Z","updatedAt":"2026-09-01T12:00:00.000Z","version":1,"occurrence":0,"archived":false},
{"id":"a3333333-3333-4333-8333-333333333333","title":"Wipe the mirror","notes":"","roomId":"bathroom","area":"mirror","dueDate":"2026-10-16","repeatDays":7,"rotation":["55555555-5555-4555-8555-555555555555","22222222-2222-4222-8222-222222222222"],"turn":0,"createdBy":"22222222-2222-4222-8222-222222222222","createdAt":"2026-09-01T12:00:00.000Z","updatedAt":"2026-09-01T12:00:00.000Z","version":1,"occurrence":0,"archived":false},
{"id":"a4444444-4444-4444-8444-444444444444","title":"Old archived task","notes":"","roomId":"kitchen","area":null,"dueDate":"2026-10-01","repeatDays":7,"rotation":["22222222-2222-4222-8222-222222222222"],"turn":0,"createdBy":"22222222-2222-4222-8222-222222222222","createdAt":"2026-09-01T12:00:00.000Z","updatedAt":"2026-09-01T12:00:00.000Z","version":1,"occurrence":0,"archived":true},
{"id":"a5555555-5555-4555-8555-555555555555","title":"Descale the kettle","notes":"","roomId":"kitchen","area":null,"dueDate":"2026-10-20","repeatDays":30,"rotation":["22222222-2222-4222-8222-222222222222"],"turn":0,"createdBy":"22222222-2222-4222-8222-222222222222","createdAt":"2026-09-01T12:00:00.000Z","updatedAt":"2026-09-01T12:00:00.000Z","version":1,"occurrence":0,"archived":false},
{"id":"a6666666-6666-4666-8666-666666666666","title":"Water the plants","notes":"","roomId":"living-room","area":"plants","dueDate":"2026-10-16","repeatDays":3,"rotation":["22222222-2222-4222-8222-222222222222"],"turn":0,"createdBy":"22222222-2222-4222-8222-222222222222","createdAt":"2026-09-01T12:00:00.000Z","updatedAt":"2026-09-01T12:00:00.000Z","version":1,"occurrence":0,"archived":false}]},
"bills":[{"id":"b1111111-1111-4111-8111-111111111111","createdAt":"2026-09-01T00:00:00.000Z","startMonth":"2026-09","pauses":[],"revisions":[{"fromMonth":"2026-09","name":"Internet","amount":4000,"dueDay":5,"participants":["22222222-2222-4222-8222-222222222222","55555555-5555-4555-8555-555555555555"]},{"fromMonth":"2026-10","name":"Fibre internet","amount":4200,"dueDay":5,"participants":["22222222-2222-4222-8222-222222222222","55555555-5555-4555-8555-555555555555"]}]}],
"expenses":[
{"id":"e1111111-1111-4111-8111-111111111111","description":"Groceries","amount":2599,"paidBy":"55555555-5555-4555-8555-555555555555","participants":["22222222-2222-4222-8222-222222222222","55555555-5555-4555-8555-555555555555"],"category":"produce","date":"2026-10-16","createdAt":"2026-10-16T09:00:00Z"},
{"id":"e2222222-2222-4222-8222-222222222222","description":"Internet","amount":4200,"paidBy":"55555555-5555-4555-8555-555555555555","participants":["22222222-2222-4222-8222-222222222222","55555555-5555-4555-8555-555555555555"],"category":"other","date":"2026-10-05","createdAt":"2026-10-05T12:00:00.000Z","bill":{"billId":"b1111111-1111-4111-8111-111111111111","month":"2026-10","dueDate":"2026-10-05"}},
{"id":"e3333333-3333-4333-8333-333333333333","description":"My own shop","amount":1000,"paidBy":"22222222-2222-4222-8222-222222222222","participants":["22222222-2222-4222-8222-222222222222","55555555-5555-4555-8555-555555555555"],"category":"pantry","date":"2026-10-15","createdAt":"2026-10-15T09:00:00.000Z"},
{"id":"e4444444-4444-4444-8444-444444444444","description":"Old shop","amount":800,"paidBy":"55555555-5555-4555-8555-555555555555","participants":["22222222-2222-4222-8222-222222222222","55555555-5555-4555-8555-555555555555"],"category":"pantry","date":"2026-09-01","createdAt":"2026-09-01T09:00:00.000Z"},
{"id":"e5555555-5555-4555-8555-555555555555","description":"Sam's snacks","amount":500,"paidBy":"55555555-5555-4555-8555-555555555555","participants":["55555555-5555-4555-8555-555555555555"],"category":"other","date":"2026-10-16","createdAt":"2026-10-16T10:00:00.000Z"},
{"id":"e6666666-6666-4666-8666-666666666666","description":"Pizza","amount":3000,"paidBy":"66666666-6666-4666-8666-666666666666","participants":["22222222-2222-4222-8222-222222222222","66666666-6666-4666-8666-666666666666","55555555-5555-4555-8555-555555555555"],"category":"other","date":"2026-10-17","createdAt":"2026-10-17T08:00:00.000Z"}],
"settlements":[
{"id":"51111111-1111-4111-8111-111111111111","from":"55555555-5555-4555-8555-555555555555","to":"22222222-2222-4222-8222-222222222222","amount":1205,"createdAt":"2026-10-10T10:00:00.000Z"},
{"id":"52222222-2222-4222-8222-222222222222","from":"22222222-2222-4222-8222-222222222222","to":"55555555-5555-4555-8555-555555555555","amount":700,"createdAt":"2026-10-11T10:00:00.000Z"},
{"id":"53333333-3333-4333-8333-333333333333","from":"55555555-5555-4555-8555-555555555555","to":"22222222-2222-4222-8222-222222222222","amount":300,"createdAt":"2026-08-01T10:00:00.000Z"}]}
"""#

    private func inbox(today: String = "2026-10-17") throws -> [InboxItem] {
        let snapshot = try ChoreFixtures.snapshot(JSONDecoder().decode(JSONValue.self, from: Data(Self.household.utf8)))
        return HouseholdInbox.items(
            chores: try HouseholdChores(household: snapshot), ledger: try HouseholdLedger(household: snapshot),
            bills: try HouseholdBills(household: snapshot), memberID: me, today: today,
            now: try #require(HouseholdInbox.timestamp("2026-10-17T12:00:00.000Z")),
            roomNames: ["kitchen": "Kitchen", "bathroom": "Bathroom", "living-room": "Living room"]
        )
    }

    /// Expected items come from running the web's `inboxItems` on the same household. Receipts and
    /// repayments target their rows where the web targets their page.
    @Test func matchesTheWebInbox() throws {
        let uuid = { (text: String) in UUID(uuidString: text)! }
        #expect(try inbox() == [
            InboxItem(id: "chore:a1111111-1111-4111-8111-111111111111:2026-10-14", kind: .chore, at: "2026-10-14T00:00:00.000Z",
                      title: "Clear the sink is 3 days overdue", detail: "Kitchen, Sink; your turn", amount: nil,
                      target: .chore(uuid("a1111111-1111-4111-8111-111111111111"))),
            InboxItem(id: "chore:a6666666-6666-4666-8666-666666666666:2026-10-16", kind: .chore, at: "2026-10-16T00:00:00.000Z",
                      title: "Water the plants is 1 day overdue", detail: "Living room; your turn", amount: nil,
                      target: .chore(uuid("a6666666-6666-4666-8666-666666666666"))),
            InboxItem(id: "chore:a2222222-2222-4222-8222-222222222222:2026-10-17", kind: .chore, at: "2026-10-17T00:00:00.000Z",
                      title: "Take out recycling is due today", detail: "Whole home; your turn", amount: nil,
                      target: .chore(uuid("a2222222-2222-4222-8222-222222222222"))),
            InboxItem(id: "expense:e6666666-6666-4666-8666-666666666666", kind: .expense, at: "2026-10-17T08:00:00.000Z",
                      title: "Former paid Pizza", detail: "Split 3 ways", amount: 3_000,
                      target: .receipt(uuid("e6666666-6666-4666-8666-666666666666"))),
            InboxItem(id: "expense:e1111111-1111-4111-8111-111111111111", kind: .expense, at: "2026-10-16T09:00:00Z",
                      title: "Sam paid Groceries", detail: "Split 2 ways", amount: 2_599,
                      target: .receipt(uuid("e1111111-1111-4111-8111-111111111111"))),
            InboxItem(id: "settlement:51111111-1111-4111-8111-111111111111", kind: .settlement, at: "2026-10-10T10:00:00.000Z",
                      title: "Sam paid you back", detail: "Repayment", amount: 1_205,
                      target: .repayment(uuid("51111111-1111-4111-8111-111111111111"))),
            InboxItem(id: "expense:e2222222-2222-4222-8222-222222222222", kind: .bill, at: "2026-10-05T12:00:00.000Z",
                      title: "Sam paid Fibre internet", detail: "Split 2 ways", amount: 4_200, target: .bills(month: "2026-10")),
        ])
    }

    @Test func readStateFollowsTheSharedCursorAndIDs() throws {
        let items = try inbox()
        let unread = InboxReadState(readThrough: nil, readIds: [])
        #expect(items.allSatisfy(unread.isUnread))
        let cursor = InboxReadState(readThrough: "2026-10-16T00:00:00.000Z", readIds: [items[3].id])
        #expect(items.filter(cursor.isUnread).map(\.id) == [items[2].id, items[4].id])
        // Marking all read moves the cursor to the newest item only.
        let all = try #require(cursor.readingAll(items))
        #expect(all == InboxRead(through: "2026-10-17T08:00:00.000Z", ids: nil))
        let read = cursor.merging(all)
        #expect(!items.contains(where: read.isUnread))
        #expect(read.readingAll(items) == nil)
        // An older cursor never moves the saved one back, and IDs keep their first order.
        let merged = read.merging(InboxRead(through: "2026-01-01T00:00:00.000Z", ids: [items[0].id, items[3].id]))
        #expect(merged.readThrough == "2026-10-17T08:00:00.000Z")
        #expect(merged.readIds == [items[3].id, items[0].id])
        let full = InboxReadState(readThrough: nil, readIds: (0..<200).map { "settlement:\(String(format: "%08d", $0))" })
        #expect(full.merging(InboxRead(through: nil, ids: ["chore:abc"])).readIds.count == 200)
    }

    @Test func readStateDecodesOnlyTheServerShape() throws {
        let decode = { (text: String) in try JSONDecoder().decode(InboxReadState.self, from: Data(text.utf8)) }
        #expect(try decode(#"{"readThrough":null,"readIds":[]}"#) == InboxReadState(readThrough: nil, readIds: []))
        #expect(try decode(#"{"readThrough":"2026-10-17T08:00:00.000Z","readIds":["chore:abc:2026-10-01"]}"#).readIds
                == ["chore:abc:2026-10-01"])
        for invalid in [#"{"readIds":[]}"#, #"{"readThrough":null,"readIds":[],"extra":1}"#,
                        #"{"readThrough":"yesterday","readIds":[]}"#, #"{"readThrough":null,"readIds":["ledger:1"]}"#] {
            #expect(throws: (any Error).self) { try decode(invalid) }
        }
    }

    @Test func loadsAndSavesReadStateOverTheNativeAccountRoute() async throws {
        let saved: [String: JSONValue] = ["readThrough": .string("2026-10-17T08:00:00.000Z"), "readIds": .array([.string("chore:abc")])]
        let transport = TestTransport(responses: [
            try Fixtures.response(Fixtures.state(selectedHousehold: true)),
            try Fixtures.response(["readThrough": .null, "readIds": .array([])], path: "api/inbox"),
            try Fixtures.response(saved, path: "api/inbox"),
            try Fixtures.response(["readThrough": .null, "readIds": .array([])], path: "api/inbox"),
        ])
        let session = AccountSession(configuration: Fixtures.configuration, tokenStore: MemoryTokenStore(token: Fixtures.oldToken),
                                     transport: transport)
        try await session.restore()
        let household = UUID(uuidString: Fixtures.householdID)!
        #expect(try await session.loadInbox(householdID: household) == InboxReadState(readThrough: nil, readIds: []))
        let load = try #require(await transport.requests.last)
        #expect(load.httpMethod == "GET")
        #expect(load.url?.path == "/api/inbox")
        #expect(load.value(forHTTPHeaderField: "Authorization") == "Bearer \(Fixtures.oldToken.value)")
        let read = InboxRead(through: "2026-10-17T08:00:00.000Z", ids: ["chore:abc"])
        #expect(try await session.markInboxRead(read, householdID: household).readIds == ["chore:abc"])
        let put = try #require(await transport.requests.last)
        #expect(put.httpMethod == "PUT")
        #expect(put.url?.path == "/api/inbox")
        let body = try JSONDecoder().decode(JSONValue.self, from: #require(put.httpBody))
        #expect(body == .object(["through": .string("2026-10-17T08:00:00.000Z"), "ids": .array([.string("chore:abc")])]))
        // A saved state that lost this device's read is not accepted as success.
        await #expect(throws: AccountError.invalidResponse) { try await session.markInboxRead(read, householdID: household) }
        await #expect(throws: AccountError.invalidInput(.notifications)) {
            try await session.markInboxRead(InboxRead(through: nil, ids: []), householdID: household)
        }
        await #expect(throws: AccountError.invalidInput(.notifications)) {
            try await session.markInboxRead(InboxRead(through: nil, ids: ["ledger:1"]), householdID: household)
        }
    }
}
