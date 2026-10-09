// The runtime contract generated code compiles against: the same declarations as
// `crates/norvo-codegen/tests/runtime_stub.swift` in the engine repository.
import Foundation

/// An operation `norvo codegen swift` generated: its document, its variables and its result type.
public protocol NorvoOperation: Sendable {
    associatedtype Data: Decodable & Sendable
    associatedtype Variables: Encodable & Sendable
    static var document: String { get }
    static var operationName: String { get }
    var variables: Variables { get }
}
public protocol NorvoQuery: NorvoOperation {}
public protocol NorvoMutation: NorvoOperation {}
public protocol NorvoSubscription: NorvoOperation {}
public protocol NorvoPurge: NorvoOperation {}

/// The variables of an operation that declares none.
public struct NoVariables: Encodable, Sendable, Hashable {
    public init() {}
}

/// A `JSON` field's value.
public enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        if let d = decoder as? _CBORDecoder {
            self = try JSONValue(cbor: d.value)
            return
        }
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int.self) {
            self = .int(i)
        } else if let x = try? c.decode(Double.self) {
            self = .double(x)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let x): try c.encode(x)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// A JSON value from Lite's CBOR form: plain CBOR with text keys.
    init(cbor: CBOR) throws {
        switch cbor {
        case .null: self = .null
        case .bool(let b): self = .bool(b)
        case .unsigned(let n): self = n <= UInt64(Int.max) ? .int(Int(n)) : .double(Double(n))
        case .negative(let n): self = n < UInt64(Int.max) ? .int(-1 - Int(n)) : .double(-1 - Double(n))
        case .double(let x): self = .double(x)
        case .text(let s): self = .string(s)
        case .array(let items): self = .array(try items.map(JSONValue.init(cbor:)))
        case .map(let pairs):
            var o: [String: JSONValue] = [:]
            for (k, v) in pairs {
                guard case .text(let key) = k else { throw CBORError.mismatch("a JSON object key is text") }
                o[key] = try JSONValue(cbor: v)
            }
            self = .object(o)
        case .bytes, .tag: throw CBORError.mismatch("a JSON value is null, a boolean, a number, text, a list or a map")
        }
    }

    /// The value as Lite reads JSON: plain CBOR.
    var cbor: CBOR {
        switch self {
        case .null: .null
        case .bool(let b): .bool(b)
        case .int(let i): CBOR(i)
        case .double(let x): .double(x)
        case .string(let s): .text(s)
        case .array(let a): .array(a.map(\.cbor))
        case .object(let o): .map(o.sorted { $0.key < $1.key }.map { (.text($0.key), $0.value.cbor) })
        }
    }
}

/// A migration as an app ships it: the complete SDL and an optional data step.
public struct Migration: Sendable, Hashable {
    public let name: String
    public let sdl: String
    public let data: String?
    public init(name: String, sdl: String, data: String?) {
        self.name = name
        self.sdl = sdl
        self.data = data
    }
}

/// Decodes a polymorphic selection's `__typename`.
public struct TypenameKey: CodingKey {
    public var stringValue: String
    public var intValue: Int? { nil }
    public init(stringValue: String) { self.stringValue = stringValue }
    public init?(intValue: Int) { nil }
    public static let typename = TypenameKey(stringValue: "__typename")
}
