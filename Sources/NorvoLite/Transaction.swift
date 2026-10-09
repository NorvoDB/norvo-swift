import CNorvoLite
import Foundation

/// An open interactive transaction, handed to `Database.transaction`'s body. Its calls run one at a time on
/// its own queue, never behind writers waiting for Lite's writer slot. It ends with the body: later calls
/// throw `.aborted`, and the Lite handle is freed only after calls already queued have run.
public final class Transaction: @unchecked Sendable {
    let database: Database
    /// Touched only on `queue`.
    private var pointer: OpaquePointer?
    private let queue = DispatchQueue(label: "norvo.lite.transaction")

    init(database: Database, pointer: OpaquePointer) {
        self.database = database
        self.pointer = pointer
    }

    static let endedError = NorvoError(code: .aborted, message: "the transaction has ended")

    private func run<T: Sendable>(_ body: @Sendable @escaping (OpaquePointer) throws -> T) async throws -> T {
        try await Database.run(on: queue) {
            guard let p = self.pointer else { throw Transaction.endedError }
            return try body(p)
        }
    }

    public func query<Q: NorvoQuery>(_ q: Q) async throws -> Q.Data {
        try await run { try self.database.execute(q, actor: nil, txn: $0) }
    }

    public func mutate<M: NorvoMutation>(_ m: M) async throws -> M.Data {
        try await run { try self.database.execute(m, actor: nil, txn: $0) }
    }

    /// Commits or rolls back, then frees the handle; queued calls run first.
    func finish(commit: Bool) async throws {
        try await Database.run(on: queue) {
            guard let p = self.pointer else { throw Transaction.endedError }
            self.pointer = nil
            defer { norvo_txn_free(p) }
            guard commit else {
                norvo_rollback(p)
                return
            }
            var err: OpaquePointer?
            let status = norvo_commit(p, nil, &err)
            guard status == 0 else { throw NorvoError.take(err, status: status) }
        }
    }
}
