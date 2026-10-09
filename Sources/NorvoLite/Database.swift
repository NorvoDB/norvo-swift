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

/// Owns the `norvo_db`. Calls borrow the pointer through `use`; `close` waits for them and later calls
/// throw, so no call reaches a closed handle.
final class Handle: @unchecked Sendable {
    private let state = NSCondition()
    private var db: OpaquePointer?
    private var inFlight = 0

    init(_ db: OpaquePointer) { self.db = db }

    static let closedError = NorvoError(code: .invalid, message: "the database is closed")

    func use<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        state.lock()
        guard let db else {
            state.unlock()
            throw Handle.closedError
        }
        inFlight += 1
        state.unlock()
        defer {
            state.lock()
            inFlight -= 1
            state.broadcast()
            state.unlock()
        }
        return try body(db)
    }

    func close() {
        state.lock()
        guard let d = db else {
            state.unlock()
            return
        }
        db = nil
        while inFlight > 0 { state.wait() }
        state.unlock()
        norvo_close(d)
    }

    deinit { close() }
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
        let stmt: OpaquePointer = try handle.use { db in
            var stmt: OpaquePointer?
            var err: OpaquePointer?
            let status = O.document.withCString { norvo_prepare(db, $0, strlen($0), &stmt, &err) }
            guard status == 0, let stmt else { throw NorvoError.take(err, status: status) }
            return stmt
        }
        cache[ObjectIdentifier(type)] = stmt
        return stmt
    }
}

public struct Seed: Sendable, Hashable {
    public let name: String
    /// A mutation document.
    public let nql: String
    /// Its variables as JSON text.
    public let variables: String?

    public init(name: String, nql: String, variables: String? = nil) {
        self.name = name
        self.nql = nql
        self.variables = variables
    }
}

public struct SeedReport: Sendable, Decodable {
    public let name: String
    public let warnings: [String]
}

/// An open Norvo Lite database. Share one per file across the app: every call is safe from any task, and
/// blocking work runs off Swift's cooperative threads.
///
/// Reads run on a concurrent queue. Writes queue on one serial queue: Lite runs one writer at a time, so at
/// most one thread waits for its writer slot, and a burst of writers cannot use up threads that reads and
/// an open transaction need. A transaction's calls run on its own queue.
public final class Database: Sendable {
    let handle: Handle
    let statements: Statements
    let writer: DispatchQueue
    let feeds = FeedCount()

    /// Live queries open on this database, for tests.
    var openFeeds: Int { feeds.value }

    static let readers = DispatchQueue(label: "norvo.lite.read", attributes: .concurrent)

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
            // Zero means Lite's default, so a zero or negative timeout waits the least it can: 1 ms.
            let ms = t.components.seconds * 1000 + t.components.attoseconds / 1_000_000_000_000_000
            opts.busy_timeout_ms = UInt64(max(ms, 1))
        }
        var db: OpaquePointer?
        var err: OpaquePointer?
        let status = (path ?? "").withCString { norvo_open(path == nil ? nil : $0, &opts, &db, &err) }
        guard status == 0, let db else { throw NorvoError.take(err, status: status) }
        handle = Handle(db)
        statements = Statements(handle)
        writer = DispatchQueue(label: "norvo.lite.write")
    }

    /// Opens or creates the database file at `url`.
    public static func open(at url: URL, options: Options = .init()) throws -> Database {
        try Database(path: url.path, options: options)
    }

    /// A database that lives in memory and ends with this value.
    public static func inMemory(options: Options = .init()) throws -> Database {
        try Database(path: nil, options: options)
    }

    /// Closes the database: open transactions roll back, live queries end, and every later call throws.
    /// It waits for calls already running.
    public func close() {
        handle.close()
    }

    /// Runs `body` on `queue` and resumes with its result.
    static func run<T: Sendable>(
        on queue: DispatchQueue = readers,
        _ body: @Sendable @escaping () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async { cont.resume(with: Result(catching: body)) }
        }
    }

    public func query<Q: NorvoQuery>(_ q: Q) async throws -> Q.Data {
        try await Database.run { try self.execute(q, actor: nil, txn: nil) }
    }

    public func mutate<M: NorvoMutation>(_ m: M, as actor: Actor) async throws -> M.Data {
        try await Database.run(on: writer) { try self.execute(m, actor: actor, txn: nil) }
    }

    public func purge<P: NorvoPurge>(_ p: P, as actor: Actor) async throws -> P.Data {
        try await Database.run(on: writer) { try self.execute(p, actor: actor, txn: nil) }
    }

    /// Runs `op`: on its own, or inside `txn` (whose actor it runs as). Throws `NorvoError` for a call that
    /// failed and `ResponseError` for a response with errors.
    func execute<O: NorvoOperation>(_ op: O, actor: Actor?, txn: OpaquePointer?) throws -> O.Data {
        let stmt = try statements.statement(O.self)
        let vars: Data =
            O.Variables.self == NoVariables.self ? Data() : try CBOREncoder().encode(op.variables).encoded()
        let bytes: Data = try handle.use { _ in
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
            return bytes
        }
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
        let list = CBOR.array(
            migrations.map { m in
                var pairs: [(CBOR, CBOR)] = [(.text("name"), .text(m.name)), (.text("sdl"), .text(m.sdl))]
                if let d = m.data { pairs.append((.text("data"), .text(d))) }
                return .map(pairs)
            }
        ).encoded()
        return try await Database.run(on: writer) {
            try self.call(list) { db, bytes, len, out, err in norvo_migrate(db, bytes, len, dryRun, out, err) }
        }
    }

    /// Runs seed files, each as one transaction, unrecorded. Seeds should upsert so re-runs converge.
    public func seed(_ seeds: [Seed]) async throws -> [SeedReport] {
        let list = CBOR.array(
            seeds.map { s in
                var pairs: [(CBOR, CBOR)] = [(.text("name"), .text(s.name)), (.text("nql"), .text(s.nql))]
                if let v = s.variables { pairs.append((.text("variables"), .text(v))) }
                return .map(pairs)
            }
        ).encoded()
        return try await Database.run(on: writer) {
            try self.call(list) { db, bytes, len, out, err in norvo_seed(db, bytes, len, out, err) }
        }
    }

    /// The stored schema as SDL; empty before the first migration.
    public func schema() async throws -> String {
        try await Database.run {
            try self.handle.use { db in
                var out = norvo_buf()
                var err: OpaquePointer?
                let status = norvo_schema(db, &out, &err)
                guard status == 0 else { throw NorvoError.take(err, status: status) }
                defer { norvo_buf_free(&out) }
                guard let data = out.data else { return "" }
                return String(decoding: UnsafeBufferPointer(start: data, count: out.len), as: UTF8.self)
            }
        }
    }

    /// Calls a Lite entry point that takes CBOR and returns CBOR, decoding the result.
    func call<T: Decodable>(
        _ input: Data,
        _ body: (
            OpaquePointer, UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<norvo_buf>,
            UnsafeMutablePointer<OpaquePointer?>
        ) -> Int32
    ) throws -> T {
        try handle.use { db in
            var out = norvo_buf()
            var err: OpaquePointer?
            let status = input.withUnsafeBytes {
                body(db, $0.bindMemory(to: UInt8.self).baseAddress, input.count, &out, &err)
            }
            guard status == 0 else { throw NorvoError.take(err, status: status) }
            defer { norvo_buf_free(&out) }
            guard let data = out.data else { throw NorvoError(code: .internal, message: "Lite returned no result") }
            return try CBORDecoder().decode(T.self, from: try CBOR.decode(Data(bytes: data, count: out.len)))
        }
    }

    /// Runs `body` in an interactive transaction as `actor`. Operations inside see its writes; nothing
    /// outside does until it commits, when `body` returns. A throw, or a cancelled task, rolls it back. The
    /// `Transaction` ends with `body`: using it afterwards throws.
    public func transaction<T: Sendable>(
        as actor: Actor,
        _ body: (Transaction) async throws -> T
    ) async throws -> T {
        let begun: TxnPointer = try await Database.run(on: writer) {
            try self.handle.use { db in
                var t: OpaquePointer?
                var err: OpaquePointer?
                let status = actor.withC { norvo_begin(db, $0, &t, &err) }
                guard status == 0, let t else { throw NorvoError.take(err, status: status) }
                return TxnPointer(t)
            }
        }
        let tx = Transaction(database: self, pointer: begun.pointer)
        do {
            let result = try await body(tx)
            try Task.checkCancellation()
            try await tx.finish(commit: true)
            return result
        } catch {
            try? await tx.finish(commit: false)
            throw error
        }
    }
}

/// A `norvo_txn` pointer crossing to the queue and back.
struct TxnPointer: @unchecked Sendable {
    let pointer: OpaquePointer
    init(_ p: OpaquePointer) { pointer = p }
}
