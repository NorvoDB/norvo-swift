import CNorvoLite
import Foundation

/// Where Lite's callback puts event bytes. Lite owns one retained reference through `ctx` and releases it
/// in `ctx_free`, which also ends the byte stream.
final class Sink: @unchecked Sendable {
    let continuation: AsyncStream<Data>.Continuation
    init(_ c: AsyncStream<Data>.Continuation) { continuation = c }
}

/// Runs on Lite's IVM thread: copies the event and returns at once.
private let onEvent: norvo_event_fn = { ctx, event, len in
    guard let ctx, let event else { return }
    Unmanaged<Sink>.fromOpaque(ctx).takeUnretainedValue().continuation.yield(Data(bytes: event, count: len))
}

/// Lite calls this once no callback can run any more.
private let onFree: norvo_free_fn = { ctx in
    guard let ctx else { return }
    Unmanaged<Sink>.fromOpaque(ctx).takeRetainedValue().continuation.finish()
}

/// Live queries of one database not yet freed.
final class FeedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add(_ d: Int) {
        lock.lock()
        n += d
        lock.unlock()
    }
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return n
    }
}

/// One live query in Lite: frees it once, on `free()` or when dropped.
final class Feed: @unchecked Sendable {
    private let lock = NSLock()
    private var sub: OpaquePointer?
    private let database: Database

    init(_ sub: OpaquePointer, database: Database) {
        self.sub = sub
        self.database = database
        database.feeds.add(1)
    }

    /// The next event is the full result.
    func resync() {
        lock.lock()
        defer { lock.unlock() }
        if let sub { norvo_sub_resync(sub) }
    }

    func free() {
        lock.lock()
        let s = sub
        sub = nil
        lock.unlock()
        guard let s else { return }
        norvo_sub_free(s)
        database.feeds.add(-1)
    }

    deinit { free() }
}

/// A live query's state after an event: the response tree's `data` and its field errors.
struct LiveUpdate: Sendable {
    let data: CBOR
    let errors: [GraphQLError]
}

extension Database {
    /// Starts `s` in Lite, its events going to `sink`. On failure Lite keeps nothing, so the sink's
    /// reference is released here.
    func openFeed<S: NorvoSubscription>(_ s: S, _ sink: Sink) throws -> Feed {
        let stmt = try statements.statement(S.self)
        let vars: Data = S.Variables.self == NoVariables.self ? Data() : try CBOREncoder().encode(s.variables).encoded()
        return try handle.use { _ in try startFeed(stmt, vars, S.operationName, sink) }
    }

    private func startFeed(_ stmt: OpaquePointer, _ vars: Data, _ operation: String, _ sink: Sink) throws -> Feed {
        let ctx = Unmanaged.passRetained(sink).toOpaque()
        var sub: OpaquePointer?
        var err: OpaquePointer?
        let status = operation.withCString { name in
            vars.withUnsafeBytes { v in
                norvo_subscribe(
                    stmt, name, v.bindMemory(to: UInt8.self).baseAddress, vars.count, onEvent, ctx, onFree, &sub, &err)
            }
        }
        guard status == 0, let sub else {
            Unmanaged<Sink>.fromOpaque(ctx).release()
            throw NorvoError.take(err, status: status)
        }
        return Feed(sub, database: self)
    }

    /// The tree of `s` after every event. Lite's callback only copies bytes; the client tree is patched
    /// here. A buffer of 256 events keeps a slow consumer bounded: an event dropped from it breaks the chain,
    /// which resyncs.
    func liveUpdates<S: NorvoSubscription>(_ s: S) -> AsyncThrowingStream<LiveUpdate, Error> {
        AsyncThrowingStream { cont in
            let (events, sinkContinuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(256))
            let task = Task {
                let feed: Feed
                do {
                    feed = try await Database.run { try self.openFeed(s, Sink(sinkContinuation)) }
                } catch {
                    cont.finish(throwing: error)
                    return
                }
                defer { feed.free() }
                var client = ClientTree()
                for await bytes in events {
                    guard let ev = try? CBOR.decode(bytes) else {
                        feed.resync()
                        continue
                    }
                    switch client.take(ev, resync: feed.resync) {
                    case .update(let data, let errors): cont.yield(LiveUpdate(data: data, errors: errors))
                    case .ended(let e):
                        cont.finish(throwing: e)
                        return
                    case .skip: break
                    }
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// `s`'s result now and after every commit that changes it. The stream throws when the live query
    /// ends (a migration made it invalid). Cancelling the consuming task frees it.
    public func subscribe<S: NorvoSubscription>(_ s: S) -> AsyncThrowingStream<S.Data, Error> {
        let updates = liveUpdates(s)
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    for try await u in updates {
                        // A null reached `data`: nothing to yield, and the errors say why.
                        if case .null = u.data {
                            throw ResponseError<S.Data>(errors: u.errors, partial: nil)
                        }
                        cont.yield(try CBORDecoder().decode(S.Data.self, from: u.data))
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}
