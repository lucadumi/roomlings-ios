import Foundation
import Testing
@testable import RoomlingsCore

@Suite("Ledger export", .timeLimit(.minutes(1)))
struct LedgerExportTests {
    private let ada = ShoppingFixtures.memberID
    private let sam = ShoppingFixtures.roommateID
    private let former = ShoppingFixtures.inactiveID
    private func id(_ value: UUID) -> JSONValue { ShoppingFixtures.id(value) }

    private var household: JSONValue {
        let base = ShoppingFixtures.household()
        let run = try! #require(base["expenses"]?.arrayValue?.first)
        return ShoppingFixtures.replacing(base, with: [
            "members": .array([
                .object(["id": id(ada), "name": .string("Ada"), "color": .string("#7d9070")]),
                .object(["id": id(sam), "name": .string("Sam"), "color": .string("#c9533a")]),
                .object(["id": id(former), "name": .string("Former"), "color": .string("#7c89a1"), "inactive": .bool(true)]),
            ]),
            "expenses": .array([
                run,
                .object([
                    "id": .string("14141414-1414-4141-8141-141414141414"), "description": .string("=HYPERLINK(\"http://x\")"),
                    "amount": .integer(450), "paidBy": id(sam), "participants": .array([id(sam)]),
                    "category": .string("produce"), "date": .string("2026-09-10"), "createdAt": .string("2026-09-10T12:00:00Z"),
                ]),
                .object([
                    "id": .string("99999999-9999-4999-8999-999999999999"), "description": .string("Internet"),
                    "amount": .integer(4_200), "paidBy": id(ada), "participants": .array([id(ada), id(sam)]),
                    "category": .string("other"), "date": .string("2026-10-05"), "createdAt": .string("2026-10-05T12:00:00.000Z"),
                    "bill": .object([
                        "billId": .string("98989898-9898-4989-8989-989898989898"), "month": .string("2026-10"),
                        "dueDate": .string("2026-10-05"),
                    ]),
                ]),
            ]),
            "settlements": .array([.object([
                "id": .string("97979797-9797-4979-8979-979797979797"), "from": id(sam), "to": id(ada),
                "amount": .integer(1_205), "createdAt": .string("2026-09-20T23:30:00.000Z"),
            ])]),
        ])
    }

    @Test func matchesTheWebReceiptBookExport() throws {
        let csv = try LedgerExport.csv(household: ShoppingFixtures.snapshot(household), roomNames: ["kitchen": "Kitchen"])
        #expect(csv == "\u{FEFF}" + [
            #""Type","Date","Description","Amount","Currency","Paid by / From","Split with / To","Category","Billing month","Shopping items""#,
            #""Expense","2026-09-01","Previous run","19.99","EUR","Former","Ada; Former","Other groceries","","1 Dish soap [Kitchen: The old sink name]""#,
            #""Expense","2026-09-10","'=HYPERLINK(""http://x"")","4.50","EUR","Sam","Sam","Fruit & veg","","""#,
            #""Bill","2026-10-05","Internet","42.00","EUR","Ada","Ada; Sam","Monthly bill","2026-10","""#,
            #""Repayment","2026-09-20","Recorded repayment","12.05","EUR","Sam","Ada","","","""#,
        ].joined(separator: "\r\n"))
    }

    @Test func purchasedItemsKeepTheirNotesAndEverySource() throws {
        var value = household
        let source = ShoppingFixtures.source
        let other = ShoppingFixtures.replacing(source, with: [
            "componentId": .string("default-bathroom-sink"), "roomId": .string("bathroom"), "componentName": .string("Basin"),
        ])
        let runs = try #require(value["shopping"]?["runs"]?.arrayValue)
        let run = ShoppingFixtures.replacing(runs[0], with: ["items": .array([
            .object([
                "id": .string("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"), "name": .string("Dish soap"), "quantity": .string("2"),
                "notes": .string("Lemon"), "createdBy": id(former), "createdAt": .string("2026-09-01T11:00:00Z"),
                "componentSources": .array([source, other]),
            ]),
            .object([
                "id": .string("abababab-abab-4bab-8bab-abababababab"), "name": .string("Oats"),
                "createdBy": id(former), "createdAt": .string("2026-09-01T11:00:00Z"),
            ]),
        ])])
        let shopping = try #require(value["shopping"])
        value = ShoppingFixtures.replacing(value, with: ["shopping": ShoppingFixtures.replacing(shopping, with: ["runs": .array([run])])])
        let csv = try LedgerExport.csv(household: ShoppingFixtures.snapshot(value), roomNames: ["kitchen": "Kitchen", "bathroom": "Bathroom"])
        #expect(csv.split(separator: "\r\n")[1].hasSuffix(#","2 Dish soap (Lemon) [Kitchen: The old sink name, Bathroom: Basin]; 1 Oats""#))
    }

    @Test(arguments: [
        ("plain", #""plain""#), ("say \"hi\"", #""say ""hi""""#), ("=1+1", #""'=1+1""#), ("+1", #""'+1""#),
        ("-5", #""'-5""#), ("@cmd", #""'@cmd""#), ("\tx", "\"'\tx\""), ("\rx", "\"'\rx\""), ("\r\nx", "\"'\r\nx\""),
        ("a=b", #""a=b""#), ("", #""""#),
    ])
    func escapesFieldsLikeTheSharedRule(value: String, expected: String) {
        #expect(LedgerExport.escape(value) == expected)
    }

    @Test(arguments: [(Int64(0), "0.00"), (5, "0.05"), (100, "1.00"), (1_999, "19.99"), (100_000_000_00, "100000000.00")])
    func formatsWholeCents(cents: Int64, expected: String) {
        #expect(LedgerExport.amount(cents) == expected)
    }
}
