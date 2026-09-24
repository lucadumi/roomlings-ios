import CoreFoundation
import Foundation
import XCTest

final class PrivacyManifestTests: XCTestCase {
    func testTheAppBundlesItsDocumentedFirstPartyPrivacyDeclarations() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let manifest = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
        )
        XCTAssertEqual(Set(manifest.keys), [
            "NSPrivacyTracking", "NSPrivacyTrackingDomains", "NSPrivacyAccessedAPITypes", "NSPrivacyCollectedDataTypes"
        ])
        XCTAssertFalse(try boolean("NSPrivacyTracking", in: manifest))
        XCTAssertEqual(manifest["NSPrivacyTrackingDomains"] as? [String], [])
        let accessed = try XCTUnwrap(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        XCTAssertTrue(accessed.isEmpty, "Update the source inventory before adding required-reason API declarations.")

        let functionality = "NSPrivacyCollectedDataTypePurposeAppFunctionality"
        let analytics = "NSPrivacyCollectedDataTypePurposeAnalytics"
        let expected: [String: Set<String>] = [
            "NSPrivacyCollectedDataTypeName": [functionality],
            "NSPrivacyCollectedDataTypeEmailAddress": [functionality],
            "NSPrivacyCollectedDataTypeContacts": [functionality],
            "NSPrivacyCollectedDataTypeOtherFinancialInfo": [functionality],
            "NSPrivacyCollectedDataTypePurchaseHistory": [functionality],
            "NSPrivacyCollectedDataTypeOtherUserContent": [functionality],
            "NSPrivacyCollectedDataTypeUserID": [functionality, analytics],
            "NSPrivacyCollectedDataTypeDeviceID": [functionality],
            "NSPrivacyCollectedDataTypeProductInteraction": [functionality, analytics]
        ]
        let collected = try XCTUnwrap(manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        var types: Set<String> = []
        for entry in collected {
            XCTAssertEqual(Set(entry.keys), [
                "NSPrivacyCollectedDataType", "NSPrivacyCollectedDataTypeLinked",
                "NSPrivacyCollectedDataTypeTracking", "NSPrivacyCollectedDataTypePurposes"
            ])
            let type = try XCTUnwrap(entry["NSPrivacyCollectedDataType"] as? String)
            XCTAssertTrue(types.insert(type).inserted, "Duplicate data declaration: \(type)")
            XCTAssertTrue(try boolean("NSPrivacyCollectedDataTypeLinked", in: entry))
            XCTAssertFalse(try boolean("NSPrivacyCollectedDataTypeTracking", in: entry))
            let purposes = try XCTUnwrap(entry["NSPrivacyCollectedDataTypePurposes"] as? [String])
            let expectedPurposes = try XCTUnwrap(expected[type], "Undocumented data type: \(type)")
            XCTAssertEqual(purposes.count, Set(purposes).count)
            XCTAssertEqual(Set(purposes), expectedPurposes, "Review data use before changing \(type).")
        }
        XCTAssertEqual(types, Set(expected.keys))
    }

    private func boolean(_ key: String, in fields: [String: Any]) throws -> Bool {
        let value = try XCTUnwrap(fields[key] as? NSNumber)
        XCTAssertEqual(CFGetTypeID(value), CFBooleanGetTypeID(), "\(key) must be a plist Boolean, not an integer.")
        return value.boolValue
    }
}
