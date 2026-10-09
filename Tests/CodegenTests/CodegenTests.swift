import Foundation
import NorvoLite
import Testing

let me = Actor(kind: .user, name: "tester", canPurge: false)

@Test func generatedOperationsRunAgainstLite() async throws {
    let db = try Database.inMemory()
    _ = try await db.migrate(NorvoSchema.migrations)
    let seen = Date(timeIntervalSince1970: 1_700_000_000.5)
    _ = try await db.mutate(
        AddNoteMutation(.init(title: "b", status: .done, seen: seen, blob: Data([1, 2]), embedding: [0.5, -1])), as: me)
    _ = try await db.mutate(AddNoteMutation(.init(title: "a")), as: me)
    let notes = try await db.query(NotesQuery()).notes
    #expect(notes.map(\.title) == ["a", "b"])
    #expect(
        notes[1].status == .done && notes[1].seen == seen && notes[1].blob == Data([1, 2])
            && notes[1].embedding == [0.5, -1])
    _ = try await db.mutate(AddApparelMutation(.init(sku: "s1")), as: me)
    let shelf = try await db.query(ShelfQuery()).products
    guard case .apparel(let a) = shelf.first else {
        Issue.record("\(shelf)")
        return
    }
    #expect(a.sku == "s1" && a.size == nil)
}

@MainActor @Test func generatedSubscriptionsLive() async throws {
    let db = try Database.inMemory()
    _ = try await db.migrate(NorvoSchema.migrations)
    let live = LiveQuery(LiveNotesSubscription(), in: db)
    _ = try await db.mutate(AddNoteMutation(.init(title: "x", status: .open)), as: me)
    for _ in 0..<500 where live.data?.notes.first?.title != "x" {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(live.data?.notes.map(\.title) == ["x"])
}
