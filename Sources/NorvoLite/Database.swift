import CNorvoLite
import Foundation

/// Who writes: every mutation and transaction runs as an actor, and history records it.
public struct Actor: Sendable, Hashable {
    public enum Kind: UInt32, Sendable { case user, agent, system }
    public let kind: Kind
    public let name: String
    /// May run `purge` operations.
    public let canPurge: Bool

    public init(kind: Kind, name: String, canPurge: Bool = false) {
        self.kind = kind
        self.name = name
        self.canPurge = canPurge
    }

    /// Calls `body` with this actor as Lite reads it.
    func withC<T>(_ body: (UnsafePointer<norvo_actor>) throws -> T) rethrows -> T {
        try name.withCString { cName in
            var a = norvo_actor(kind: kind.rawValue, name: cName, grants: canPurge ? NORVO_GRANT_PURGE : 0)
            return try body(&a)
        }
    }
}

public struct Options: Sendable {
    /// For a new file; an existing one keeps its own.
    public var pageSize: UInt32?
    /// The most entities one operation may examine.
    public var maxExamined: UInt64?
    /// How long a writer waits for an open transaction before it fails with `.busy`.
    public var busyTimeout: Duration?

    public init(pageSize: UInt32? = nil, maxExamined: UInt64? = nil, busyTimeout: Duration? = nil) {
        self.pageSize = pageSize
        self.maxExamined = maxExamined
        self.busyTimeout = busyTimeout
    }
}

public struct MigrationReport: Sendable, Decodable {
    public let applied: [String]
    public let pending: [String]
}

/// Owns the `norvo_db`; closes it when the last reference goes.
final class Handle: @unchecked Sendable {
    let db: OpaquePointer
    init(_ db: OpaquePointer) { self.db = db }
    deinit { norvo_close(db) }
}

/// Compiled statements, one per operation type, prepared on first use.
final class Statements: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [ObjectIdentifier: OpaquePointer] = [:]
    let handle: Handle

    init(_ handle: Handle) { self.handle = handle }

    deinit {
        for stmt in cache.values { norvo_stmt_free(stmt) }
    }

    func statement<O: NorvoOperation>(_ type: O.Type) throws -> OpaquePointer {
        lock.lock()
        defer { lock.unlock() }
        if let s = cache[ObjectIdentifier(type)] { return s }
        var stmt: OpaquePointer?
        var err: OpaquePointer?
        let text = O.document
        let status = text.withCString { norvo_prepare(handle.db, $0, strlen($0), &stmt, &err) }
        guard status == 0, let stmt else { throw NorvoError.take(err, status: status) }
        cache[ObjectIdentifier(type)] = stmt
        return stmt
    }
}

/// An open Norvo Lite database. Share one per file across the app: every call is safe from any task, and
/// blocking work runs off Swift's cooperative threads.
public final class Database: Sendable {
    let handle: Handle
    let statements: Statements

    /// Blocking calls into Lite run here, so the cooperative pool never waits on the writer or the disk.
    static let queue = DispatchQueue(label: "norvo.lite", attributes: .concurrent)

    private init(path: String?, options: Options) throws {
        guard norvo_abi_version() == UInt32(NORVO_ABI_VERSION) else {
            throw NorvoError(
                code: .internal,
                message: "the Lite library has ABI \(norvo_abi_version()); this package expects \(NORVO_ABI_VERSION)"
            )
        }
        var opts = norvo_open_opts()
        opts.struct_size = MemoryLayout<norvo_open_opts>.size
        opts.page_size = options.pageSize ?? 0
        opts.in_memory = path == nil
        opts.max_examined = options.maxExamined ?? 0
        if let t = options.busyTimeout {
            opts.busy_timeout_ms = UInt64(t.components.seconds) * 1000 + UInt64(t.components.attoseconds / 1_000_000_000_000_000)
        }
        var db: OpaquePointer?
        var err: OpaquePointer?
        let status = (path ?? "").withCString { norvo_open(path == nil ? nil : $0, &opts, &db, &err) }
        guard status == 0, let db else { throw NorvoError.take(err, status: status) }
        handle = Handle(db)
        statements = Statements(handle)
    }

    /// Opens or creates the database file at `url`.
    public static func open(at url: URL, options: Options = .init()) throws -> Database {
        try Database(path: url.path, options: options)
    }

    /// A database that lives in memory and ends with this value.
    public static func inMemory(options: Options = .init()) throws -> Database {
        try Database(path: nil, options: options)
    }

    /// Runs `body` on Lite's queue and resumes with its result.
    static func run<T: Sendable>(_ body: @Sendable @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async { cont.resume(with: Result(catching: body)) }
        }
    }

    public func query<Q: NorvoQuery>(_ q: Q) async throws -> Q.Data {
        try await Database.run { try self.execute(q, actor: nil, txn: nil) }
    }

    public func mutate<M: NorvoMutation>(_ m: M, as actor: Actor) async throws -> M.Data {
        try await Database.run { try self.execute(m, actor: actor, txn: nil) }
    }

    public func purge<P: NorvoPurge>(_ p: P, as actor: Actor) async throws -> P.Data {
        try await Database.run { try self.execute(p, actor: actor, txn: nil) }
    }

    /// Runs `op`: on its own, or inside `txn` (whose actor it runs as). Throws `NorvoError` for a call that
    /// failed and `ResponseError` for a response with errors.
    func execute<O: NorvoOperation>(_ op: O, actor: Actor?, txn: OpaquePointer?) throws -> O.Data {
        let stmt = try statements.statement(O.self)
        let vars: Data = O.Variables.self == NoVariables.self ? Data() : try CBOREncoder().encode(op.variables).encoded()
        var out = norvo_buf()
        var err: OpaquePointer?
        let status: Int32 = O.operationName.withCString { name in
            vars.withUnsafeBytes { v in
                let bytes = v.bindMemory(to: UInt8.self).baseAddress
                if let actor {
                    return actor.withC { a in norvo_exec(stmt, name, bytes, vars.count, a, txn, &out, &err) }
                }
                return norvo_exec(stmt, name, bytes, vars.count, nil, txn, &out, &err)
            }
        }
        guard out.len > 0, let data = out.data else {
            norvo_buf_free(&out)
            throw NorvoError.take(err, status: status)
        }
        let bytes = Data(bytes: data, count: out.len)
        norvo_buf_free(&out)
        if let err { norvo_error_free(err) }
        return try Database.decodeResponse(O.Data.self, bytes)
    }

    /// `{data, errors}` as `D`, or `ResponseError` when it carries errors.
    static func decodeResponse<D: Decodable & Sendable>(_ type: D.Type, _ bytes: Data) throws -> D {
        let r = try CBOR.decode(bytes)
        let data = r["data"] ?? .null
        if let errors = r["errors"] {
            let list = try CBORDecoder().decode([GraphQLError].self, from: errors)
            let partial: D? = if case .null = data { nil } else { try? CBORDecoder().decode(D.self, from: data) }
            throw ResponseError(errors: list, partial: partial)
        }
        return try CBORDecoder().decode(D.self, from: data)
    }

    /// Applies the pending migrations of `migrations`, the list the app ships, in order. A dry run runs the
    /// first pending one and rolls it back.
    public func migrate(_ migrations: [Migration], dryRun: Bool = false) async throws -> MigrationReport {
        let list = CBOR.array(migrations.map { m in
            var pairs: [(CBOR, CBOR)] = [(.text("name"), .text(m.name)), (.text("sdl"), .text(m.sdl))]
            if let d = m.data { pairs.append((.text("data"), .text(d))) }
            return .map(pairs)
        }).encoded()
        return try await Database.run {
            try self.call(list) { bytes, len, out, err in norvo_migrate(self.handle.db, bytes, len, dryRun, out, err) }
        }
    }

    /// The stored schema as SDL; empty before the first migration.
    public func schema() async throws -> String {
        try await Database.run {
            var out = norvo_buf()
            var err: OpaquePointer?
            let status = norvo_schema(self.handle.db, &out, &err)
            guard status == 0 else { throw NorvoError.take(err, status: status) }
            defer { norvo_buf_free(&out) }
            guard let data = out.data else { return "" }
            return String(decoding: UnsafeBufferPointer(start: data, count: out.len), as: UTF8.self)
        }
    }

    /// Calls a Lite entry point that takes CBOR and returns CBOR, decoding the result.
    func call<T: Decodable>(
        _ input: Data,
        _ body: (UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<norvo_buf>, UnsafeMutablePointer<OpaquePointer?>) -> Int32
    ) throws -> T {
        var out = norvo_buf()
        var err: OpaquePointer?
        let status = input.withUnsafeBytes { body($0.bindMemory(to: UInt8.self).baseAddress, input.count, &out, &err) }
        guard status == 0 else { throw NorvoError.take(err, status: status) }
        defer { norvo_buf_free(&out) }
        guard let data = out.data else { throw NorvoError(code: .internal, message: "Lite returned no result") }
        return try CBORDecoder().decode(T.self, from: try CBOR.decode(Data(bytes: data, count: out.len)))
    }

    /// Runs `body` in an interactive transaction as `actor`. Operations inside see its writes; nothing
    /// outside does until it commits, when `body` returns. A throw, or a cancelled task, rolls it back.
    public func transaction<T: Sendable>(as actor: Actor, _ body: (Transaction) async throws -> T) async throws -> T {
        let txn: OpaquePointer = try await Database.run {
            var t: OpaquePointer?
            var err: OpaquePointer?
            let status = actor.withC { norvo_begin(self.handle.db, $0, &t, &err) }
            guard status == 0, let t else { throw NorvoError.take(err, status: status) }
            return TxnPointer(t)
        }.pointer
        let tx = Transaction(database: self, pointer: txn)
        defer { norvo_txn_free(txn) }
        do {
            let result = try await body(tx)
            try Task.checkCancellation()
            let committing = TxnPointer(txn)
            try await Database.run {
                var err: OpaquePointer?
                let status = norvo_commit(committing.pointer, nil, &err)
                guard status == 0 else { throw NorvoError.take(err, status: status) }
            }
            return result
        } catch {
            norvo_rollback(txn)
            throw error
        }
    }
}

/// A `norvo_txn` pointer crossing to the queue and back.
struct TxnPointer: @unchecked Sendable {
    let pointer: OpaquePointer
    init(_ p: OpaquePointer) { pointer = p }
}
