import Foundation
import Testing

@testable import NorvoLite

/// Writers waiting on Lite's writer slot must not starve reads or the open transaction: past GCD's thread
/// limit, waiting writers on a shared queue blocked both.
@Test func manyWaitingWritersStarveNeitherReadsNorTheTransaction() async throws {
    let db = try Database.inMemory(options: .init(busyTimeout: .seconds(20)))
    _ = try await db.migrate([Migration(name: "0001_init", sdl: tagSDL, data: nil)])
    let clock = ContinuousClock()
    let started = clock.now
    // The writers wait for the transaction's writer slot, so the body must not wait for them.
    let writers = try await db.transaction(as: me) { tx in
        let writers = (0..<150).map { i in
            Task { try await db.mutate(AddTag(variables: .init(label: "w\(i)", rank: i)), as: me) }
        }
        // Let the writers queue up behind the transaction.
        try await Task.sleep(for: .milliseconds(300))
        let q = clock.now
        _ = try await db.query(Tags())
        #expect(clock.now - q < .seconds(1), "a read waited behind writers")
        _ = try await tx.mutate(AddTag(variables: .init(label: "in-tx", rank: 0)))
        return writers
    }
    #expect(clock.now - started < .seconds(5), "the transaction waited behind writers")
    for w in writers { _ = try await w.value }
    #expect(try await db.query(Tags()).tags.count == 151)
}

@Test func anEscapedTransactionThrowsInsteadOfTouchingFreedMemory() async throws {
    let db = try await freshDatabase()
    nonisolated(unsafe) var escaped: Transaction?
    try await db.transaction(as: me) { tx in escaped = tx }
    await #expect {
        _ = try await escaped!.query(Tags())
    } throws: { ($0 as? NorvoError)?.code == .aborted }
}

@Test func seedsRunAndCloseEndsTheDatabase() async throws {
    let db = try await freshDatabase()
    let reports = try await db.seed([
        Seed(name: "tags", nql: #"mutation { upsertTag(by: {label: "s"}, input: {label: "s"}) { label } }"#)
    ])
    #expect(reports.map(\.name) == ["tags"])
    #expect(try await db.query(Tags()).tags.map(\.label) == ["s"])
    var live = db.subscribe(LiveTags()).makeAsyncIterator()
    _ = try await live.next()
    db.close()
    #expect(try await live.next() == nil, "closing ends live queries")
    await #expect {
        _ = try await db.query(Tags())
    } throws: { ($0 as? NorvoError)?.code == .invalid }
}

struct Owner: NorvoMutation {
    static let operationName = "Owner"
    static let document = #"mutation Owner { createOwner(input: {name: "o"}) { name } }"#
    typealias Variables = NoVariables
    var variables: NoVariables { NoVariables() }
    struct Data: Decodable, Sendable {}
}

struct Pet: NorvoMutation {
    static let operationName = "Pet"
    static let document = #"mutation Pet { createPet(input: {name: "p", owner: {connect: {name: "o"}}}) { name } }"#
    typealias Variables = NoVariables
    var variables: NoVariables { NoVariables() }
    struct Data: Decodable, Sendable {}
}

struct Orphan: NorvoMutation {
    static let operationName = "Orphan"
    static let document = #"mutation Orphan { deleteOwner(by: {name: "o"}) }"#
    typealias Variables = NoVariables
    var variables: NoVariables { NoVariables() }
    struct Data: Decodable, Sendable {}
}

struct Pets: NorvoSubscription {
    static let operationName = "Pets"
    static let document = "subscription Pets { pets { name owner { name } } }"
    typealias Variables = NoVariables
    var variables: NoVariables { NoVariables() }
    struct Data: Decodable, Sendable {
        let pets: [P]
        struct P: Decodable, Sendable { let name: String }
    }
}

@Test func subscribeEndsWithTheErrorsWhenDataGoesNull() async throws {
    let db = try Database.inMemory()
    let sdl = "type Owner { name: String! @unique }\ntype Pet { name: String! @unique  owner: Owner! }\n"
    _ = try await db.migrate([Migration(name: "0001_init", sdl: sdl, data: nil)])
    _ = try await db.mutate(Owner(), as: me)
    _ = try await db.mutate(Pet(), as: me)
    var pets = db.subscribe(Pets()).makeAsyncIterator()
    #expect(try await pets.next()?.pets.count == 1)
    // A required ref to a deleted owner reads null, which bubbles to `data`.
    _ = try await db.mutate(Orphan(), as: me)
    await #expect {
        _ = try await pets.next()
    } throws: { ($0 as? ResponseError<Pets.Data>)?.errors.isEmpty == false }
}
