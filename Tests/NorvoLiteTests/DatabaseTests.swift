import Foundation
import Testing
@testable import NorvoLite

let tagSDL = "type Tag { label: String! @unique  rank: Int }\n"

struct Tags: NorvoQuery {
    static let operationName = "Tags"
    static let document = "query Tags { tags(orderBy: [{label: ASC}]) { label rank } }"
    typealias Variables = NoVariables
    var variables: NoVariables { NoVariables() }
    struct Data: Decodable, Sendable, Equatable {
        let tags: [T]
        struct T: Decodable, Sendable, Equatable { let label: String; let rank: Int? }
    }
}

struct AddTag: NorvoMutation {
    static let operationName = "AddTag"
    static let document = "mutation AddTag($label: String!, $rank: Int) { createTag(input: {label: $label, rank: $rank}) { label } }"
    struct Variables: Encodable, Sendable { let label: String; let rank: Int? }
    let variables: Variables
    struct Data: Decodable, Sendable { let createTag: L; struct L: Decodable, Sendable { let label: String } }
}

let me = Actor(kind: .user, name: "tester", canPurge: false)

func freshDatabase() async throws -> Database {
    let db = try Database.inMemory()
    _ = try await db.migrate([Migration(name: "0001_init", sdl: tagSDL, data: nil)])
    return db
}

@Test func queriesAndMutationsRoundTrip() async throws {
    let db = try await freshDatabase()
    _ = try await db.mutate(AddTag(variables: .init(label: "b", rank: 2)), as: me)
    _ = try await db.mutate(AddTag(variables: .init(label: "a", rank: nil)), as: me)
    #expect(try await db.query(Tags()) == .init(tags: [.init(label: "a", rank: nil), .init(label: "b", rank: 2)]))
}

@Test func failuresThrowTypedErrors() async throws {
    let db = try await freshDatabase()
    _ = try await db.mutate(AddTag(variables: .init(label: "a", rank: nil)), as: me)
    await #expect {
        _ = try await db.mutate(AddTag(variables: .init(label: "a", rank: nil)), as: me)
    } throws: { e in
        (e as? ResponseError<AddTag.Data>)?.errors.first?.code == "CONSTRAINT"
    }
    struct Bad: NorvoQuery {
        static let operationName = "Bad"
        static let document = "query Bad { tags { lable } }"
        typealias Variables = NoVariables
        var variables: NoVariables { NoVariables() }
        struct Data: Decodable, Sendable {}
    }
    await #expect {
        _ = try await db.query(Bad())
    } throws: { e in
        guard let e = e as? NorvoError else { return false }
        return e.code == .invalid && e.hint?.contains("label") == true && e.line == 1
    }
}

@Test func transactionsCommitOrRollBack() async throws {
    let db = try await freshDatabase()
    try await db.transaction(as: me) { tx in
        _ = try await tx.mutate(AddTag(variables: .init(label: "in", rank: 1)))
        #expect(try await tx.query(Tags()).tags.map(\.label) == ["in"])
    }
    struct Boom: Error {}
    await #expect(throws: Boom.self) {
        try await db.transaction(as: me) { tx in
            _ = try await tx.mutate(AddTag(variables: .init(label: "gone", rank: 1)))
            throw Boom()
        }
    }
    #expect(try await db.query(Tags()).tags.map(\.label) == ["in"])
}

@Test func manyTasksShareOneDatabase() async throws {
    let db = try await freshDatabase()
    try await withThrowingTaskGroup(of: Void.self) { group in
        for i in 0..<20 {
            group.addTask { _ = try await db.mutate(AddTag(variables: .init(label: "t\(i)", rank: i)), as: me) }
            group.addTask { _ = try await db.query(Tags()) }
        }
        try await group.waitForAll()
    }
    #expect(try await db.query(Tags()).tags.count == 20)
}

@Test func schemaAndMigrationsReport() async throws {
    let db = try Database.inMemory()
    let report = try await db.migrate([Migration(name: "0001_init", sdl: tagSDL, data: nil)], dryRun: true)
    #expect(report.applied.isEmpty && report.pending == ["0001_init"])
    _ = try await db.migrate([Migration(name: "0001_init", sdl: tagSDL, data: nil)])
    #expect(try await db.schema().contains("type Tag"))
}
