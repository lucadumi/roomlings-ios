import Foundation

public struct ChoreDraft: Sendable, Equatable {
    public let title: String
    public let notes: String
    public let roomID: String?
    public let area: String?
    public let componentID: String?
    public let dueDate: String
    public let repeatDays: Int?
    public let rotation: [UUID]
    public let turn: Int

    public init(
        title: String, notes: String = "", roomID: String? = nil, area: String? = nil,
        componentID: String? = nil, dueDate: String, repeatDays: Int? = nil,
        rotation: [UUID], turn: Int = 0
    ) throws {
        guard let title = ChoreValidation.text(title, length: 1...80) else {
            throw AccountError.invalidInput(.title)
        }
        guard let notes = ChoreValidation.text(notes, length: 0...240) else {
            throw AccountError.invalidInput(.notes)
        }
        try ChoreValidation.location(roomID: roomID, area: area, componentID: componentID)
        guard ChoreValidation.date(dueDate) else { throw AccountError.invalidInput(.dueDate) }
        guard repeatDays.map({ (1...365).contains($0) }) ?? true else {
            throw AccountError.invalidInput(.repeatDays)
        }
        guard (1...12).contains(rotation.count), Set(rotation).count == rotation.count,
              rotation.allSatisfy(ChoreValidation.uuid) else {
            throw AccountError.invalidInput(.rotation)
        }
        guard rotation.indices.contains(turn) else { throw AccountError.invalidInput(.turn) }
        self.title = title
        self.notes = notes
        self.roomID = roomID
        self.area = area
        self.componentID = componentID
        self.dueDate = dueDate
        self.repeatDays = repeatDays
        self.rotation = rotation
        self.turn = turn
    }

    var requestFields: [String: JSONValue] {
        [
            "title": .string(title), "notes": .string(notes),
            "roomId": roomID.map(JSONValue.string) ?? .null,
            "area": area.map(JSONValue.string) ?? .null,
            "componentId": componentID.map(JSONValue.string) ?? .null,
            "dueDate": .string(dueDate), "repeatDays": repeatDays.map { .integer(Int64($0)) } ?? .null,
            "rotation": .array(rotation.map { .string($0.uuidString.lowercased()) }),
            "turn": .integer(Int64(turn))
        ]
    }
}

public enum ChoreStatus: String, Sendable {
    case archived, completed, overdue, due, upcoming
}

public struct Chore: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let title: String
    public let notes: String
    public let roomID: String?
    public let area: String?
    public let componentID: String?
    public let componentName: String?
    public let dueDate: String?
    public let repeatDays: Int?
    public let rotation: [UUID]
    public let turn: Int
    public let createdBy: UUID
    public let createdAt: String
    public let updatedAt: String
    public let version: Int64
    public let occurrence: Int64
    public let archived: Bool

    /// Compare calendar dates in the household's time zone; no schedule is advanced locally.
    public func status(on today: String) throws -> ChoreStatus {
        guard ChoreValidation.date(today, minimumYear: 0) else { throw AccountError.invalidInput(.dueDate) }
        if archived { return .archived }
        guard let dueDate else { return .completed }
        if dueDate < today { return .overdue }
        return dueDate == today ? .due : .upcoming
    }

    init(_ value: JSONValue) throws {
        let fields = try ChoreFields(value)
        id = try fields.uuid("id")
        title = try fields.text("title", length: 1...80)
        notes = try fields.text("notes", length: 0...240, default: "")
        roomID = try fields.nullableString("roomId")
        area = try fields.nullableString("area")
        componentID = try fields.nullableString("componentId", optional: true)
        componentName = try fields.optionalName("componentName")
        try ChoreValidation.responseLocation(roomID: roomID, area: area, componentID: componentID)
        dueDate = try fields.nullableString("dueDate")
        guard dueDate.map({ ChoreValidation.date($0) }) ?? true else { throw AccountError.invalidResponse }
        repeatDays = try fields.nullableInteger("repeatDays", range: 1...365).map(Int.init)
        rotation = try fields.array("rotation").map { value in
            guard let raw = value.stringValue, let id = ChoreValidation.uuid(raw) else {
                throw AccountError.invalidResponse
            }
            return id
        }
        turn = Int(try fields.integer("turn", range: 0...11, default: 0))
        guard (1...12).contains(rotation.count), Set(rotation).count == rotation.count,
              rotation.indices.contains(turn), dueDate != nil || repeatDays == nil else {
            throw AccountError.invalidResponse
        }
        createdBy = try fields.uuid("createdBy")
        createdAt = try fields.timestamp("createdAt")
        updatedAt = try fields.timestamp("updatedAt")
        version = try fields.integer("version")
        occurrence = try fields.integer("occurrence")
        archived = try fields.bool("archived")
        guard occurrence <= version else { throw AccountError.invalidResponse }
    }
}

public struct ChoreCompletion: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let choreID: UUID
    public let occurrence: Int64
    public let title: String
    public let roomID: String?
    public let area: String?
    public let componentID: String?
    public let componentName: String?
    public let dueDate: String
    public let turn: Int
    public let assignedTo: UUID?
    public let completedBy: UUID
    public let completedAt: String
    public let resultVersion: Int64
    public let undoneAt: String?
    public let undoneBy: UUID?

    init(_ value: JSONValue) throws {
        let fields = try ChoreFields(value)
        id = try fields.uuid("id")
        choreID = try fields.uuid("choreId")
        occurrence = try fields.integer("occurrence")
        title = try fields.text("title", length: 1...80)
        roomID = try fields.nullableString("roomId")
        area = try fields.nullableString("area")
        componentID = try fields.nullableString("componentId", optional: true)
        componentName = try fields.optionalName("componentName")
        try ChoreValidation.responseLocation(roomID: roomID, area: area, componentID: componentID)
        dueDate = try fields.string("dueDate")
        guard ChoreValidation.date(dueDate) else { throw AccountError.invalidResponse }
        turn = Int(try fields.integer("turn", range: 0...11))
        assignedTo = try fields.nullableUUID("assignedTo")
        completedBy = try fields.uuid("completedBy")
        completedAt = try fields.timestamp("completedAt")
        resultVersion = try fields.integer("resultVersion", range: 1...ChoreValidation.maximumInteger)
        undoneAt = try fields.nullableString("undoneAt")
        undoneBy = try fields.nullableUUID("undoneBy")
        guard undoneAt.map(AccountValidation.timestamp) ?? true,
              (undoneAt == nil) == (undoneBy == nil), resultVersion > occurrence else {
            throw AccountError.invalidResponse
        }
    }
}

public typealias ChoreMember = HouseholdMember

/// A validated native projection, not a replacement ledger or an account/renderer payload.
public struct HouseholdChores: Sendable, Equatable {
    public let items: [Chore]
    public let history: [ChoreCompletion]
    public let members: [ChoreMember]
    public let billingTimeZone: String
    public let timeZone: HouseholdTimeZone
    public var activeMembers: [ChoreMember] { members.filter { !$0.inactive } }

    private let components: [String: HouseholdComponent]

    public init(household: HouseholdSnapshot) throws {
        let fields = try ChoreFields(household.value)
        if household.value["billingTimeZone"] == nil {
            billingTimeZone = "UTC"
        } else {
            billingTimeZone = try fields.string("billingTimeZone")
        }
        timeZone = try HouseholdTimeZone(identifier: billingTimeZone)
        members = try HouseholdMember.projection(household.value)
        let memberIDs = Set(members.map(\.id))
        components = try HouseholdComponent.projection(household: household.value)
        if let chores = household.value["chores"] {
            let fields = try ChoreFields(chores)
            let rawItems = try fields.array("items")
            let rawHistory = try fields.array("history")
            guard rawItems.count <= 200, rawHistory.count <= 20_000 else { throw AccountError.invalidResponse }
            items = try rawItems.map(Chore.init)
            history = try rawHistory.map(ChoreCompletion.init)
        } else {
            // The shared household schema explicitly defaults only an absent chores field.
            items = []
            history = []
        }
        var byID: [UUID: Chore] = [:]
        for chore in items {
            guard byID.updateValue(chore, forKey: chore.id) == nil,
                  memberIDs.contains(chore.createdBy), chore.rotation.allSatisfy(memberIDs.contains) else {
                throw AccountError.invalidResponse
            }
            if let id = chore.componentID {
                guard let component = components[id], component.roomID == chore.roomID,
                      chore.area == nil || component.area == chore.area else { throw AccountError.invalidResponse }
            }
        }
        var completionIDs = Set<UUID>()
        var activeOccurrences: [UUID: Set<Int64>] = [:]
        for completion in history {
            guard completionIDs.insert(completion.id).inserted,
                  let chore = byID[completion.choreID], completion.resultVersion <= chore.version,
                  memberIDs.contains(completion.completedBy),
                  completion.assignedTo.map(memberIDs.contains) ?? true,
                  completion.undoneBy.map(memberIDs.contains) ?? true else { throw AccountError.invalidResponse }
            if completion.undoneAt == nil {
                guard completion.occurrence < chore.occurrence,
                      activeOccurrences[chore.id, default: []].insert(completion.occurrence).inserted else {
                    throw AccountError.invalidResponse
                }
            }
            if let id = completion.componentID {
                guard components[id]?.roomID == completion.roomID else { throw AccountError.invalidResponse }
            }
        }
    }

    public func assignee(for chore: Chore) -> ChoreMember? {
        for offset in chore.rotation.indices {
            let id = chore.rotation[(chore.turn + offset) % chore.rotation.count]
            if let member = members.first(where: { $0.id == id && !$0.inactive }) { return member }
        }
        return nil
    }

    public func isPaused(_ chore: Chore) -> Bool {
        guard !chore.archived, let id = chore.componentID else { return false }
        return components[id]?.installed == false
    }

    public func canUndo(_ completion: ChoreCompletion) -> Bool {
        guard completion.undoneAt == nil, history.contains(completion),
              let chore = items.first(where: { $0.id == completion.choreID }) else { return false }
        return !chore.archived && chore.version == completion.resultVersion
            && chore.occurrence == completion.occurrence + 1
    }
}

enum ChoreValidation {
    static let maximumInteger = HouseholdValidation.maximumInteger
    static let areas: [String: Set<String>] = [
        "kitchen": ["sink", "counters", "fridge", "floor", "bins"],
        "bathroom": ["sink", "mirror", "toilet", "bath", "floor"],
        "living-room": ["seating", "surfaces", "floor", "bins", "plants"]
    ]

    static func text(_ value: String, length: ClosedRange<Int>) -> String? {
        HouseholdValidation.text(value, length: length)
    }

    static func uuid(_ raw: String) -> UUID? {
        HouseholdValidation.uuid(raw)
    }

    static func uuid(_ id: UUID) -> Bool { uuid(id.uuidString) != nil }

    static func date(_ value: String, minimumYear: Int = 1900) -> Bool {
        guard AccountValidation.matches(value, #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#) else { return false }
        let parts = value.split(separator: "-")
        guard let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              year >= minimumYear, (1...12).contains(month) else { return false }
        let leap = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
        let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return (1...lengths[month - 1]).contains(day)
    }

    static func componentID(_ value: String) -> Bool {
        HouseholdValidation.componentID(value)
    }

    static func location(roomID: String?, area: String?, componentID: String?) throws {
        if let roomID, areas[roomID] == nil { throw AccountError.invalidInput(.roomID) }
        if let area, roomID.flatMap({ areas[$0]?.contains(area) }) != true {
            throw AccountError.invalidInput(.area)
        }
        if let componentID, roomID == nil || !Self.componentID(componentID) {
            throw AccountError.invalidInput(.componentID)
        }
    }

    static func responseLocation(roomID: String?, area: String?, componentID: String?) throws {
        do {
            try location(roomID: roomID, area: area, componentID: componentID)
        } catch {
            throw AccountError.invalidResponse
        }
    }
}

typealias ChoreFields = HouseholdFields
