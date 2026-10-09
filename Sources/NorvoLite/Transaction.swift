import Foundation

/// An open interactive transaction, handed to `Database.transaction`'s body. Use it from that body's task
/// only: Lite runs one call at a time in a transaction.
public final class Transaction: @unchecked Sendable {
    let database: Database
    let pointer: OpaquePointer

    init(database: Database, pointer: OpaquePointer) {
        self.database = database
        self.pointer = pointer
    }

    public func query<Q: NorvoQuery>(_ q: Q) async throws -> Q.Data {
        try await Database.run { try self.database.execute(q, actor: nil, txn: self.pointer) }
    }

    public func mutate<M: NorvoMutation>(_ m: M) async throws -> M.Data {
        try await Database.run { try self.database.execute(m, actor: nil, txn: self.pointer) }
    }
}
