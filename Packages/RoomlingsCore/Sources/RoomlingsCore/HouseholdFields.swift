import Foundation

public struct HouseholdMember: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let color: String
    public let inactive: Bool

    init(_ value: JSONValue) throws {
        let fields = try HouseholdFields(value)
        id = try fields.uuid("id")
        name = try fields.text("name", length: 1...50)
        color = try fields.string("color")
        inactive = try fields.bool("inactive", default: false)
    }

    static func projection(_ household: JSONValue) throws -> [HouseholdMember] {
        let members = try HouseholdFields(household).array("members").map(Self.init)
        guard (1...200).contains(members.count), Set(members.map(\.id)).count == members.count,
              members.filter({ !$0.inactive }).count <= 12 else { throw AccountError.invalidResponse }
        return members
    }
}

public struct HouseholdMemberColor: Sendable, Equatable {
    public let rgb: UInt32

    public init?(hex: String) {
        guard hex.hasPrefix("#") else { return nil }
        let digits = hex.dropFirst()
        guard [3, 6].contains(digits.count),
              digits.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        let expanded = digits.count == 3 ? digits.map { "\($0)\($0)" }.joined() : String(digits)
        guard let rgb = UInt32(expanded, radix: 16) else { return nil }
        self.rgb = rgb
    }
}

enum HouseholdValidation {
    static let maximumInteger: Int64 = 9_007_199_254_740_991

    static func text(_ value: String, length: ClosedRange<Int>) -> String? {
        // JavaScript String.trim(), including BOM but not the Unicode next-line character.
        let whitespace = CharacterSet(charactersIn:
            "\u{0009}\u{000A}\u{000B}\u{000C}\u{000D}\u{0020}\u{00A0}\u{1680}" +
            "\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}" +
            "\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}"
        )
        let normalized = value.trimmingCharacters(in: whitespace)
        return length.contains(normalized.utf16.count) ? normalized : nil
    }

    static func uuid(_ raw: String) -> UUID? {
        let pattern = #"^(?:[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}|00000000-0000-0000-0000-000000000000|ffffffff-ffff-ffff-ffff-ffffffffffff)$"#
        guard AccountValidation.matches(raw.lowercased(), pattern) else { return nil }
        return UUID(uuidString: raw)
    }

    static func uuid(_ id: UUID) -> Bool { uuid(id.uuidString) != nil }

    static func componentID(_ value: String) -> Bool {
        (1...80).contains(value.utf16.count) && AccountValidation.matches(value, #"^[a-z0-9][a-z0-9-]*$"#)
    }
}

struct HouseholdFields {
    let object: [String: JSONValue]

    init(_ value: JSONValue) throws {
        guard case .object(let object) = value else { throw AccountError.invalidResponse }
        self.object = object
    }

    func string(_ key: String) throws -> String {
        guard let value = object[key]?.stringValue else { throw AccountError.invalidResponse }
        return value
    }

    func nullableString(_ key: String, optional: Bool = false) throws -> String? {
        if object[key] == .null || (optional && object[key] == nil) { return nil }
        return try string(key)
    }

    func text(_ key: String, length: ClosedRange<Int>, default fallback: String? = nil) throws -> String {
        if object[key] == nil, let fallback { return fallback }
        guard let value = HouseholdValidation.text(try string(key), length: length) else {
            throw AccountError.invalidResponse
        }
        return value
    }

    func optionalName(_ key: String) throws -> String? {
        guard object[key] != nil else { return nil }
        return try text(key, length: 1...50)
    }

    func uuid(_ key: String) throws -> UUID {
        guard let id = HouseholdValidation.uuid(try string(key)) else { throw AccountError.invalidResponse }
        return id
    }

    func nullableUUID(_ key: String) throws -> UUID? {
        guard let raw = try nullableString(key) else { return nil }
        guard let id = HouseholdValidation.uuid(raw) else { throw AccountError.invalidResponse }
        return id
    }

    func integer(
        _ key: String, range: ClosedRange<Int64> = 0...HouseholdValidation.maximumInteger,
        default fallback: Int64? = nil
    ) throws -> Int64 {
        if object[key] == nil, let fallback { return fallback }
        guard let value = object[key]?.integerValue, range.contains(value) else { throw AccountError.invalidResponse }
        return value
    }

    func nullableInteger(_ key: String, range: ClosedRange<Int64>) throws -> Int64? {
        if object[key] == .null { return nil }
        return try integer(key, range: range)
    }

    func timestamp(_ key: String) throws -> String {
        let value = try string(key)
        guard AccountValidation.timestamp(value) else { throw AccountError.invalidResponse }
        return value
    }

    func bool(_ key: String, default fallback: Bool? = nil) throws -> Bool {
        if object[key] == nil, let fallback { return fallback }
        guard case .bool(let value) = object[key] else { throw AccountError.invalidResponse }
        return value
    }

    func array(_ key: String) throws -> [JSONValue] {
        guard let value = object[key]?.arrayValue else { throw AccountError.invalidResponse }
        return value
    }
}
