import Foundation

/// Encodes `Encodable` values as CBOR the way Lite reads it: `UUID` as tag 37, `Date` as tag 1001,
/// `Data` as a byte string, `[Float]` as tag 85, `JSONValue` as plain CBOR. A nil optional encoded with
/// `encodeIfPresent` writes nothing, so the operation's default applies.
public struct CBOREncoder: Sendable {
    public init() {}

    public func encode<T: Encodable>(_ value: T) throws -> CBOR {
        try _CBOREncoder.box(value, path: [])
    }
}

/// A value under construction: containers add to it after they are handed out.
final class Node {
    enum Kind {
        case empty
        case value(CBOR)
        case map([(String, Node)])
        case array([Node])
    }

    var kind: Kind = .empty

    var cbor: CBOR {
        switch kind {
        case .empty: .map([])
        case .value(let v): v
        case .map(let fields): .map(fields.map { (.text($0.0), $0.1.cbor) })
        case .array(let items): .array(items.map(\.cbor))
        }
    }
}

final class _CBOREncoder: Encoder {
    let node: Node
    let codingPath: [any CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    init(_ node: Node, path: [any CodingKey]) {
        self.node = node
        self.codingPath = path
    }

    /// `value` as CBOR, with Lite's tagged types first.
    static func box<T: Encodable>(_ value: T, path: [any CodingKey]) throws -> CBOR {
        switch value {
        case let id as UUID:
            return .tag(37, .bytes(withUnsafeBytes(of: id.uuid) { Data($0) }))
        case let date as Date:
            let msDouble = (date.timeIntervalSince1970 * 1000).rounded()
            // Int64 milliseconds cover ±292 million years; anything else (and NaN) is refused, not trapped on.
            guard msDouble.isFinite, msDouble >= -9.2e18, msDouble <= 9.2e18 else {
                throw EncodingError.invalidValue(
                    date, .init(codingPath: path, debugDescription: "the date is out of range"))
            }
            let ms = Int64(msDouble)
            let (secs, rest) = (ms.floorDiv(1000), ms.floorMod(1000))
            var pairs: [(CBOR, CBOR)] = [(.unsigned(1), CBOR(Int(secs)))]
            if rest != 0 { pairs.append((.negative(2), .unsigned(UInt64(rest)))) }
            return .tag(1001, .map(pairs))
        case let data as Data:
            return .bytes(data)
        case let floats as [Float]:
            var b = Data(capacity: floats.count * 4)
            for f in floats { withUnsafeBytes(of: f.bitPattern.littleEndian) { b.append(contentsOf: $0) } }
            return .tag(85, .bytes(b))
        case let json as JSONValue:
            return json.cbor
        default:
            let node = Node()
            try value.encode(to: _CBOREncoder(node, path: path))
            return node.cbor
        }
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        if case .map = node.kind {} else { node.kind = .map([]) }
        return KeyedEncodingContainer(Keyed<Key>(node: node, codingPath: codingPath))
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        if case .array = node.kind {} else { node.kind = .array([]) }
        return Unkeyed(node: node, codingPath: codingPath)
    }

    func singleValueContainer() -> any SingleValueEncodingContainer {
        Single(node: node, codingPath: codingPath)
    }

    struct Keyed<Key: CodingKey>: KeyedEncodingContainerProtocol {
        let node: Node
        let codingPath: [any CodingKey]

        func put(_ key: Key, _ child: Node) {
            guard case .map(var fields) = node.kind else { return }
            fields.removeAll { $0.0 == key.stringValue }
            fields.append((key.stringValue, child))
            node.kind = .map(fields)
        }

        mutating func encodeNil(forKey key: Key) throws {
            let n = Node()
            n.kind = .value(.null)
            put(key, n)
        }

        mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
            let n = Node()
            n.kind = .value(try _CBOREncoder.box(value, path: codingPath + [key]))
            put(key, n)
        }

        mutating func nestedContainer<N: CodingKey>(keyedBy type: N.Type, forKey key: Key) -> KeyedEncodingContainer<N>
        {
            let n = Node()
            put(key, n)
            return _CBOREncoder(n, path: codingPath + [key]).container(keyedBy: type)
        }

        mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
            let n = Node()
            put(key, n)
            return _CBOREncoder(n, path: codingPath + [key]).unkeyedContainer()
        }

        mutating func superEncoder() -> any Encoder { _CBOREncoder(node, path: codingPath) }

        mutating func superEncoder(forKey key: Key) -> any Encoder {
            let n = Node()
            put(key, n)
            return _CBOREncoder(n, path: codingPath + [key])
        }
    }

    struct Unkeyed: UnkeyedEncodingContainer {
        let node: Node
        let codingPath: [any CodingKey]
        var count: Int {
            if case .array(let items) = node.kind { return items.count }
            return 0
        }

        func append(_ child: Node) {
            guard case .array(var items) = node.kind else { return }
            items.append(child)
            node.kind = .array(items)
        }

        mutating func encodeNil() throws {
            let n = Node()
            n.kind = .value(.null)
            append(n)
        }

        mutating func encode<T: Encodable>(_ value: T) throws {
            let n = Node()
            n.kind = .value(try _CBOREncoder.box(value, path: codingPath + [_CBORDecoder.Index(count)]))
            append(n)
        }

        mutating func nestedContainer<N: CodingKey>(keyedBy type: N.Type) -> KeyedEncodingContainer<N> {
            let n = Node()
            append(n)
            return _CBOREncoder(n, path: codingPath).container(keyedBy: type)
        }

        mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
            let n = Node()
            append(n)
            return _CBOREncoder(n, path: codingPath).unkeyedContainer()
        }

        mutating func superEncoder() -> any Encoder {
            let n = Node()
            append(n)
            return _CBOREncoder(n, path: codingPath)
        }
    }

    struct Single: SingleValueEncodingContainer {
        let node: Node
        let codingPath: [any CodingKey]

        mutating func encodeNil() throws { node.kind = .value(.null) }
        mutating func encode(_ value: Bool) throws { node.kind = .value(.bool(value)) }
        mutating func encode(_ value: String) throws { node.kind = .value(.text(value)) }
        mutating func encode(_ value: Double) throws { node.kind = .value(.double(value)) }
        mutating func encode(_ value: Float) throws { node.kind = .value(.double(Double(value))) }
        mutating func encode(_ value: Int) throws { node.kind = .value(CBOR(value)) }
        mutating func encode(_ value: Int8) throws { node.kind = .value(CBOR(Int(value))) }
        mutating func encode(_ value: Int16) throws { node.kind = .value(CBOR(Int(value))) }
        mutating func encode(_ value: Int32) throws { node.kind = .value(CBOR(Int(value))) }
        mutating func encode(_ value: Int64) throws { node.kind = .value(CBOR(Int(value))) }
        mutating func encode(_ value: UInt) throws { node.kind = .value(.unsigned(UInt64(value))) }
        mutating func encode(_ value: UInt8) throws { node.kind = .value(.unsigned(UInt64(value))) }
        mutating func encode(_ value: UInt16) throws { node.kind = .value(.unsigned(UInt64(value))) }
        mutating func encode(_ value: UInt32) throws { node.kind = .value(.unsigned(UInt64(value))) }
        mutating func encode(_ value: UInt64) throws { node.kind = .value(.unsigned(value)) }
        mutating func encode<T: Encodable>(_ value: T) throws {
            node.kind = .value(try _CBOREncoder.box(value, path: codingPath))
        }
    }
}

extension Int64 {
    func floorDiv(_ d: Int64) -> Int64 { (self - floorMod(d)) / d }
    func floorMod(_ d: Int64) -> Int64 { ((self % d) + d) % d }
}
