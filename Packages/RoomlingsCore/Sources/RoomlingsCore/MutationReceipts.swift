import Foundation

/// The shared receipt ledger proves the server applied exactly this mutation once, so every
/// household mutation confirms its own receipt before trusting the returned projection.
enum MutationReceipts {
    static func confirm(
        _ household: HouseholdSnapshot, version: Int64, mutationID: UUID, memberID: UUID
    ) throws {
        let receipts = try HouseholdFields(household.value).array("mutationReceipts")
        guard (1...1_000).contains(receipts.count) else { throw AccountError.invalidResponse }
        var receiptIDs = Set<UUID>()
        var previousVersion: Int64 = 0
        var confirmed = false
        for value in receipts {
            let fields = try HouseholdFields(value)
            let id = try fields.uuid("id")
            let author = try fields.uuid("memberId")
            let resultVersion = try fields.integer("version", range: 1...HouseholdValidation.maximumInteger)
            guard receiptIDs.insert(id).inserted, household.memberIDs.contains(author),
                  resultVersion > previousVersion, resultVersion <= household.version,
                  AccountValidation.matches(try fields.string("fingerprint"), #"^[a-f0-9]{64}$"#) else {
                throw AccountError.invalidResponse
            }
            if id == mutationID {
                guard author == memberID, resultVersion == version + 1 else { throw AccountError.invalidResponse }
                confirmed = true
            }
            previousVersion = resultVersion
        }
        guard confirmed else { throw AccountError.invalidResponse }
    }
}
