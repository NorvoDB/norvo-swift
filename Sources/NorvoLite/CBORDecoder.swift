import Foundation

/// Decodes `Decodable` values from CBOR the way Lite writes it: `UUID` from tag 37, `Date` from tag 1001
/// (or tag 1), `Data` from a byte string, `[Float]` from tag 85, `JSONValue` from plain CBOR.
public struct CBORDecoder: Sendable {
    public init() {}

    public func decode<T: Decodable>(_ type: T.Type, from value: CBOR) throws -> T {
        try _CBORDecoder.unbox(type, value, path: [])
    }
}

final class _CBORDecoder: Decoder {
    let value: CBOR
    let codingPath: [any CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    init(_ value: CBOR, path: [any CodingKey]) {
        self.value = value
        self.codingPath = path
    }

    static func mismatch<T>(_ type: T.Type, _ value: CBOR, _ path: [any CodingKey]) -> DecodingError {
        .typeMismatch(type, .init(codingPath: path, debugDescription: "found \(value)"))
    }

    /// `value` as a `T`, with Lite's tagged types first.
    static func unbox<T: Decodable>(_ type: T.Type, _ value: CBOR, path: [any CodingKey]) throws -> T {
        if type == UUID.self {
            guard case .tag(37, .bytes(let b)) = value, b.count == 16 else { throw mismatch(type, value, path) }
            let t = b.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) }
            return UUID(uuid: t) as! T
        }
        if type == Date.self {
            switch value {
            case .tag(1001, .map(let pairs)):
                var secs = 0.0
                var ms = 0.0
                for (k, v) in pairs {
                    let n = try unbox(Double.self, v, path: path)
                    switch k {
                    case .unsigned(1): secs = n
                    case .negative(2): ms = n
                    default: break
                    }
                }
                return Date(timeIntervalSince1970: secs + ms / 1000) as! T
            case .tag(1, let n):
                return Date(timeIntervalSince1970: try unbox(Double.self, n, path: path)) as! T
            default: throw mismatch(type, value, path)
            }
        }
        if type == Data.self {
            guard case .bytes(let b) = value else { throw mismatch(type, value, path) }
            return b as! T
        }
        if type == [Float].self, case .tag(85, .bytes(let b)) = value {
            guard b.count % 4 == 0 else { throw mismatch(type, value, path) }
            let floats = stride(from: 0, to: b.count, by: 4).map { i in
                Float(
                    bitPattern: b.withUnsafeBytes {
                        UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: i, as: UInt32.self))
                    })
            }
            return floats as! T
        }
        if type == JSONValue.self {
            return try JSONValue(cbor: value) as! T
        }
        return try T(from: _CBORDecoder(value, path: path))
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case .map(let pairs) = value else { throw Self.mismatch([String: CBOR].self, value, codingPath) }
        var fields: [String: CBOR] = [:]
        for (k, v) in pairs {
            if case .text(let key) = k, fields[key] == nil { fields[key] = v }
        }
        return KeyedDecodingContainer(Keyed<Key>(fields: fields, codingPath: codingPath))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        guard case .array(let items) = value else { throw Self.mismatch([CBOR].self, value, codingPath) }
        return Unkeyed(items: items, codingPath: codingPath)
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        Single(value: value, codingPath: codingPath)
    }

    struct Keyed<Key: CodingKey>: KeyedDecodingContainerProtocol {
        let fields: [String: CBOR]
        let codingPath: [any CodingKey]
        var allKeys: [Key] { fields.keys.compactMap(Key.init(stringValue:)) }

        func contains(_ key: Key) -> Bool { fields[key.stringValue] != nil }

        func field(_ key: Key) throws -> CBOR {
            guard let v = fields[key.stringValue] else {
                throw DecodingError.keyNotFound(
                    key, .init(codingPath: codingPath, debugDescription: "no `\(key.stringValue)`"))
            }
            return v
        }

        func decodeNil(forKey key: Key) throws -> Bool {
            if case .null = fields[key.stringValue] ?? .null { return true }
            return false
        }

        func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
            try _CBORDecoder.unbox(type, try field(key), path: codingPath + [key])
        }

        func nestedContainer<N: CodingKey>(keyedBy type: N.Type, forKey key: Key) throws -> KeyedDecodingContainer<N> {
            try _CBORDecoder(try field(key), path: codingPath + [key]).container(keyedBy: type)
        }

        func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
            try _CBORDecoder(try field(key), path: codingPath + [key]).unkeyedContainer()
        }

        func superDecoder() throws -> any Decoder {
            _CBORDecoder(.map(fields.map { (.text($0.key), $0.value) }), path: codingPath)
        }
        func superDecoder(forKey key: Key) throws -> any Decoder {
            _CBORDecoder(try field(key), path: codingPath + [key])
        }
    }

    struct Index: CodingKey {
        let intValue: Int?
        var stringValue: String { "\(intValue ?? 0)" }
        init(_ i: Int) { intValue = i }
        init?(stringValue: String) { nil }
        init?(intValue: Int) { self.intValue = intValue }
    }

    struct Unkeyed: UnkeyedDecodingContainer {
        let items: [CBOR]
        let codingPath: [any CodingKey]
        var currentIndex = 0
        var count: Int? { items.count }
        var isAtEnd: Bool { currentIndex >= items.count }

        mutating func next() throws -> (CBOR, [any CodingKey]) {
            guard !isAtEnd else {
                throw DecodingError.valueNotFound(
                    CBOR.self, .init(codingPath: codingPath, debugDescription: "the list has ended"))
            }
            defer { currentIndex += 1 }
            return (items[currentIndex], codingPath + [Index(currentIndex)])
        }

        mutating func decodeNil() throws -> Bool {
            guard !isAtEnd, case .null = items[currentIndex] else { return false }
            currentIndex += 1
            return true
        }

        mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
            let (v, path) = try next()
            return try _CBORDecoder.unbox(type, v, path: path)
        }

        mutating func nestedContainer<N: CodingKey>(keyedBy type: N.Type) throws -> KeyedDecodingContainer<N> {
            let (v, path) = try next()
            return try _CBORDecoder(v, path: path).container(keyedBy: type)
        }

        mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
            let (v, path) = try next()
            return try _CBORDecoder(v, path: path).unkeyedContainer()
        }

        mutating func superDecoder() throws -> any Decoder {
            let (v, path) = try next()
            return _CBORDecoder(v, path: path)
        }
    }

    struct Single: SingleValueDecodingContainer {
        let value: CBOR
        let codingPath: [any CodingKey]

        func decodeNil() -> Bool {
            if case .null = value { return true }
            return false
        }

        func decode(_ type: Bool.Type) throws -> Bool {
            guard case .bool(let b) = value else { throw _CBORDecoder.mismatch(type, value, codingPath) }
            return b
        }

        func decode(_ type: String.Type) throws -> String {
            guard case .text(let s) = value else { throw _CBORDecoder.mismatch(type, value, codingPath) }
            return s
        }

        func decode(_ type: Double.Type) throws -> Double {
            switch value {
            case .double(let x): return x
            case .unsigned(let n): return Double(n)
            case .negative(let n): return -1 - Double(n)
            default: throw _CBORDecoder.mismatch(type, value, codingPath)
            }
        }

        func decode(_ type: Float.Type) throws -> Float { Float(try decode(Double.self)) }

        func integer<I: FixedWidthInteger>(_ type: I.Type) throws -> I {
            switch value {
            case .unsigned(let n):
                guard let i = I(exactly: n) else { throw _CBORDecoder.mismatch(type, value, codingPath) }
                return i
            case .negative(let n):
                guard n < UInt64(Int64.max), let i = I(exactly: -1 - Int64(n)) else {
                    throw _CBORDecoder.mismatch(type, value, codingPath)
                }
                return i
            default: throw _CBORDecoder.mismatch(type, value, codingPath)
            }
        }

        func decode(_ type: Int.Type) throws -> Int { try integer(type) }
        func decode(_ type: Int8.Type) throws -> Int8 { try integer(type) }
        func decode(_ type: Int16.Type) throws -> Int16 { try integer(type) }
        func decode(_ type: Int32.Type) throws -> Int32 { try integer(type) }
        func decode(_ type: Int64.Type) throws -> Int64 { try integer(type) }
        func decode(_ type: UInt.Type) throws -> UInt { try integer(type) }
        func decode(_ type: UInt8.Type) throws -> UInt8 { try integer(type) }
        func decode(_ type: UInt16.Type) throws -> UInt16 { try integer(type) }
        func decode(_ type: UInt32.Type) throws -> UInt32 { try integer(type) }
        func decode(_ type: UInt64.Type) throws -> UInt64 { try integer(type) }

        func decode<T: Decodable>(_ type: T.Type) throws -> T {
            try _CBORDecoder.unbox(type, value, path: codingPath)
        }
    }
}
