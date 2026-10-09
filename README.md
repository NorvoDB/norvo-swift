# NorvoLite for Swift

The Swift package for [Norvo Lite](https://github.com/NorvoDB): an embedded database with NorvoQL, a
GraphQL-based query language, and live queries that push changes after every commit. macOS 14+ and iOS 17+.

## Add it

```swift
.package(url: "https://github.com/NorvoDB/norvo-swift.git", branch: "main"),
```

Depend on the `NorvoLite` product, and apply the `NorvoCodegen` plugin to the target that holds your
NorvoQL project:

```swift
.target(
    name: "App",
    dependencies: [.product(name: "NorvoLite", package: "norvo-swift")],
    exclude: ["schema.nql", "migrations", "operations"],
    plugins: [.plugin(name: "NorvoCodegen", package: "norvo-swift")]
),
```

The target's directory holds `schema.nql`, `migrations/` (snapshot migrations, `NNNN_name.nql`) and any
other `.nql` files with operations and fragments. Fragments are shared across files. The plugin writes one
typed Swift type per operation: `RecentNotesQuery`, `AddNoteMutation`, `InboxSubscription`.

## Use it

```swift
import NorvoLite

let db = try Database.open(at: url)
_ = try await db.migrate(NorvoSchema.migrations)

let me = Actor(kind: .user, name: "me")
_ = try await db.mutate(AddNoteMutation(.init(title: "Hello")), as: me)
let notes = try await db.query(NotesQuery()).notes

try await db.transaction(as: me) { tx in
    let current = try await tx.query(NotesQuery())
    _ = try await tx.mutate(AddNoteMutation(.init(title: "#\(current.notes.count)")))
}

for try await inbox in db.subscribe(InboxSubscription()) {
    print(inbox.notes.count)
}
```

In SwiftUI, `LiveQuery` follows the database:

```swift
struct Inbox: View {
    @State private var live: LiveQuery<InboxSubscription>
    init(db: Database) { _live = State(initialValue: LiveQuery(InboxSubscription(), in: db)) }
    var body: some View {
        List(live.data?.notes ?? [], id: \.id) { Text($0.title) }
    }
}
```

Errors: a failed call throws `NorvoError` (code, message, line and column, hint); a response with errors
throws `ResponseError` with the errors and, for queries, the partial data.

## Develop

`.githooks/pre-push` runs `swift format lint`, `swift build` and `swift test` before a push. Enable it once
per clone:

```sh
git config core.hooksPath .githooks
```

To build against a local engine checkout instead of the published binaries:

```sh
scripts/use-local.sh ../database   # builds the engine and links Artifacts/
NORVO_LOCAL=1 swift test
```
