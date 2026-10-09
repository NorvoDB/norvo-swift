import Foundation
import Testing

@testable import NorvoLite

struct LiveTags: NorvoSubscription {
    static let operationName = "LiveTags"
    static let document = "subscription LiveTags { tags(orderBy: [{rank: ASC}]) { label rank } }"
    typealias Variables = NoVariables
    var variables: NoVariables { NoVariables() }
    typealias Data = Tags.Data
}

@Test func patchesApplyInOrderToNestedLists() throws {
    var tree = CBOR.map([(.text("a"), .array([.map([(.text("l"), .array([.unsigned(1), .unsigned(2)]))])]))])
    let patches: CBOR = .array([
        .map([
            (.text("op"), .text("insert")),
            (.text("path"), .array([.text("a"), .unsigned(0), .text("l"), .unsigned(2)])),
            (.text("value"), .unsigned(3)),
        ]),
        .map([
            (.text("op"), .text("move")),
            (.text("path"), .array([.text("a"), .unsigned(0), .text("l"), .unsigned(2)])), (.text("to"), .unsigned(0)),
        ]),
        .map([
            (.text("op"), .text("remove")),
            (.text("path"), .array([.text("a"), .unsigned(0), .text("l"), .unsigned(1)])),
        ]),
    ])
    try Patches.apply(patches, to: &tree)
    #expect(tree == .map([(.text("a"), .array([.map([(.text("l"), .array([.unsigned(3), .unsigned(2)]))])]))]))
    var bad = tree
    #expect(throws: (any Error).self) {
        try Patches.apply(
            .array([.map([(.text("op"), .text("remove")), (.text("path"), .array([.text("a"), .unsigned(9)]))])]),
            to: &bad)
    }
}

@Test func subscribeYieldsTheResultAfterEachCommit() async throws {
    let db = try await freshDatabase()
    var results = db.subscribe(LiveTags()).makeAsyncIterator()
    #expect(try await results.next()?.tags == [])
    _ = try await db.mutate(AddTag(variables: .init(label: "x", rank: 2)), as: me)
    #expect(try await results.next()?.tags.map(\.label) == ["x"])
    _ = try await db.mutate(AddTag(variables: .init(label: "y", rank: 1)), as: me)
    // The subscription orders by rank: y (1) before x (2).
    #expect(try await results.next()?.tags.map(\.label) == ["y", "x"])
}

@Test func cancellingTheConsumerFreesTheSubscription() async throws {
    let db = try await freshDatabase()
    let consumer = Task {
        for try await _ in db.subscribe(LiveTags()) {}
    }
    try await Task.sleep(for: .milliseconds(50))
    consumer.cancel()
    _ = try? await consumer.value
    for i in 0..<20 {
        _ = try await db.mutate(AddTag(variables: .init(label: "c\(i)", rank: i)), as: me)
    }
    #expect(Feed.live == 0, "every feed freed")
}

@MainActor @Test func liveQueryTracksTheDatabase() async throws {
    let db = try await freshDatabase()
    let live = LiveQuery(LiveTags(), in: db)
    try await until { live.data != nil }
    _ = try await db.mutate(AddTag(variables: .init(label: "z", rank: 1)), as: me)
    try await until { live.data?.tags.map(\.label) == ["z"] }
    #expect(live.errors.isEmpty && live.ended == nil)
}

@MainActor @Test func aMigrationThatBreaksTheOperationEndsIt() async throws {
    let db = try await freshDatabase()
    let live = LiveQuery(LiveTags(), in: db)
    try await until { live.data != nil }
    _ = try await db.migrate([
        Migration(name: "0001_init", sdl: tagSDL, data: nil),
        Migration(name: "0002_drop_rank", sdl: "type Tag { label: String! @unique }\n", data: nil),
    ])
    try await until { live.ended != nil }
    #expect(live.ended?.message.contains("rank") == true)
}

/// Waits up to 5 s for `condition`, on the main actor.
@MainActor func until(_ condition: () -> Bool) async throws {
    for _ in 0..<500 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out")
}
