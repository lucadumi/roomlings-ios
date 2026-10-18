import Foundation

struct InboxAPI: Sendable {
    let client: NativeAPIClient

    func load(token: SessionToken) async throws -> InboxReadState {
        try await client.request(.inbox, token: token)
    }

    func read(_ read: InboxRead, token: SessionToken) async throws -> InboxReadState {
        guard read.through != nil || !(read.ids ?? []).isEmpty,
              (read.ids ?? []).allSatisfy(InboxRead.validID), (read.ids ?? []).count <= InboxReadState.readLimit else {
            throw AccountError.invalidInput(.notifications)
        }
        let result: InboxReadState = try await client.request(.readInbox, body: JSONEncoder().encode(read), token: token)
        // The server merges reads, so a saved state never loses what this device just read.
        guard read.through.map({ through in result.readThrough.map { $0 >= through } ?? false }) ?? true,
              (read.ids ?? []).allSatisfy({ result.readIds.contains($0) }) else { throw AccountError.invalidResponse }
        return result
    }
}
