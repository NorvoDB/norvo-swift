import Foundation

/// Applies a live query's patches to the client's tree, as NorvoQL spec section 5 says: in order, each
/// index against the tree the previous patches left; insert, remove and move act on the list the path's
/// last segment indexes.
enum Patches {
    enum Misfit: Error { case path, op }

    static func apply(_ patches: CBOR, to tree: inout CBOR) throws {
        guard case .array(let list) = patches else { throw Misfit.op }
        for p in list {
            guard case .text(let op)? = p["op"], case .array(let path)? = p["path"] else { throw Misfit.op }
            if op == "set" {
                guard let value = p["value"] else { throw Misfit.op }
                try at(path[...], in: &tree) { $0 = value }
                continue
            }
            guard case .unsigned(let i)? = path.last else { throw Misfit.path }
            let index = Int(clamping: i)
            try at(path.dropLast(), in: &tree) { list in
                guard case .array(var items) = list else { throw Misfit.path }
                switch op {
                case "insert":
                    guard index <= items.count, let value = p["value"] else { throw Misfit.path }
                    items.insert(value, at: index)
                case "remove":
                    guard index < items.count else { throw Misfit.path }
                    items.remove(at: index)
                case "move":
                    guard index < items.count, case .unsigned(let t)? = p["to"] else { throw Misfit.path }
                    let item = items.remove(at: index)
                    let to = Int(clamping: t)
                    guard to <= items.count else { throw Misfit.path }
                    items.insert(item, at: to)
                default: throw Misfit.op
                }
                list = .array(items)
            }
        }
    }

    /// Runs `change` on the value at `path` inside `tree`.
    private static func at(_ path: ArraySlice<CBOR>, in tree: inout CBOR, _ change: (inout CBOR) throws -> Void) throws {
        guard let first = path.first else {
            try change(&tree)
            return
        }
        switch (tree, first) {
        case (.map(var pairs), .text(let key)):
            guard let i = pairs.firstIndex(where: { if case .text(key) = $0.0 { true } else { false } }) else {
                throw Misfit.path
            }
            var child = pairs[i].1
            try at(path.dropFirst(), in: &child, change)
            pairs[i].1 = child
            tree = .map(pairs)
        case (.array(var items), .unsigned(let n)):
            let i = Int(clamping: n)
            guard i < items.count else { throw Misfit.path }
            var child = items[i]
            try at(path.dropFirst(), in: &child, change)
            items[i] = child
            tree = .array(items)
        default:
            throw Misfit.path
        }
    }
}

/// The tree a live query's client holds, kept current by events.
struct ClientTree {
    var data: CBOR?
    var seq: UInt64 = 0
    /// A resync was asked for: patches wait for the next full result.
    var awaitingFull = false

    enum Outcome {
        case update(CBOR, [GraphQLError])
        case ended(NorvoError)
        case skip
    }

    /// Takes one event. A patch event that does not chain onto `seq`, or does not fit, asks for a resync
    /// and is dropped.
    mutating func take(_ ev: CBOR, resync: () -> Void) -> Outcome {
        let errors = (ev["errors"]).flatMap { try? CBORDecoder().decode([GraphQLError].self, from: $0) } ?? []
        if let ended = ev["ended"] {
            let first = (try? CBORDecoder().decode([GraphQLError].self, from: ended))?.first
            return .ended(NorvoError(
                code: NorvoError.Code(responseCode: first?.code),
                message: first?.message ?? "the live query ended"
            ))
        }
        if case .unsigned(let s)? = ev["seq"] {
            data = ev["data"] ?? .null
            seq = s
            awaitingFull = false
            return .update(data!, errors)
        }
        guard !awaitingFull else { return .skip }
        guard case .unsigned(let from)? = ev["from"], case .unsigned(let to)? = ev["to"], let patches = ev["patches"],
              from == seq, var tree = data
        else {
            awaitingFull = true
            resync()
            return .skip
        }
        do {
            try Patches.apply(patches, to: &tree)
        } catch {
            awaitingFull = true
            resync()
            return .skip
        }
        data = tree
        seq = to
        return .update(tree, errors)
    }
}
