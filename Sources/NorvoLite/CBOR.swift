import Foundation

/// A CBOR value (RFC 8949), as Lite writes and reads them. Maps keep their order: a response's fields
/// follow the selection.
public indirect enum CBOR: Sendable {
    case unsigned(UInt64)
    /// `-1 - n`.
    case negative(UInt64)
    case bytes(Data)
    case text(String)
    case array([CBOR])
    case map([(CBOR, CBOR)])
    case tag(UInt64, CBOR)
    case bool(Bool)
    case null
    case double(Double)

    public init(_ i: Int) {
        self = i >= 0 ? .unsigned(UInt64(i)) : .negative(UInt64(-1 - i))
    }

    /// The value of the text key `key` in a map.
    public subscript(key: String) -> CBOR? {
        guard case .map(let pairs) = self else { return nil }
        return pairs.first { if case .text(key) = $0.0 { true } else { false } }?.1
    }
}

extension CBOR: Hashable {
    public static func == (a: CBOR, b: CBOR) -> Bool {
        switch (a, b) {
        case (.unsigned(let x), .unsigned(let y)), (.negative(let x), .negative(let y)): x == y
        case (.bytes(let x), .bytes(let y)): x == y
        case (.text(let x), .text(let y)): x == y
        case (.array(let x), .array(let y)): x == y
        case (.map(let x), .map(let y)): x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case (.tag(let t, let x), .tag(let u, let y)): t == u && x == y
        case (.bool(let x), .bool(let y)): x == y
        case (.null, .null): true
        case (.double(let x), .double(let y)): x.bitPattern == y.bitPattern
        default: false
        }
    }

    public func hash(into h: inout Hasher) {
        switch self {
        case .unsigned(let x): h.combine(0); h.combine(x)
        case .negative(let x): h.combine(1); h.combine(x)
        case .bytes(let x): h.combine(2); h.combine(x)
        case .text(let x): h.combine(3); h.combine(x)
        case .array(let x): h.combine(4); h.combine(x)
        case .map(let x):
            h.combine(5)
            for (k, v) in x { h.combine(k); h.combine(v) }
        case .tag(let t, let x): h.combine(6); h.combine(t); h.combine(x)
        case .bool(let x): h.combine(7); h.combine(x)
        case .null: h.combine(8)
        case .double(let x): h.combine(9); h.combine(x.bitPattern)
        }
    }
}

public enum CBORError: Error, Sendable, Equatable {
    case malformed(String)
    case mismatch(String)
}

// MARK: Encoding

extension CBOR {
    /// The value in CBOR's binary form, with definite lengths.
    public func encoded() -> Data {
        var out = Data()
        write(into: &out)
        return out
    }

    private static func head(_ major: UInt8, _ n: UInt64, into out: inout Data) {
        let m = major << 5
        switch n {
        case 0..<24: out.append(m | UInt8(n))
        case 24...0xff: out.append(m | 24); out.append(UInt8(n))
        case 0x100...0xffff: out.append(m | 25); out.append(contentsOf: withUnsafeBytes(of: UInt16(n).bigEndian, Array.init))
        case 0x10000...0xffff_ffff: out.append(m | 26); out.append(contentsOf: withUnsafeBytes(of: UInt32(n).bigEndian, Array.init))
        default: out.append(m | 27); out.append(contentsOf: withUnsafeBytes(of: n.bigEndian, Array.init))
        }
    }

    private func write(into out: inout Data) {
        switch self {
        case .unsigned(let n): CBOR.head(0, n, into: &out)
        case .negative(let n): CBOR.head(1, n, into: &out)
        case .bytes(let b): CBOR.head(2, UInt64(b.count), into: &out); out.append(b)
        case .text(let s):
            let u = Data(s.utf8)
            CBOR.head(3, UInt64(u.count), into: &out)
            out.append(u)
        case .array(let items):
            CBOR.head(4, UInt64(items.count), into: &out)
            for i in items { i.write(into: &out) }
        case .map(let pairs):
            CBOR.head(5, UInt64(pairs.count), into: &out)
            for (k, v) in pairs { k.write(into: &out); v.write(into: &out) }
        case .tag(let t, let v): CBOR.head(6, t, into: &out); v.write(into: &out)
        case .bool(let b): out.append(b ? 0xf5 : 0xf4)
        case .null: out.append(0xf6)
        case .double(let x):
            out.append(0xfb)
            out.append(contentsOf: withUnsafeBytes(of: x.bitPattern.bigEndian, Array.init))
        }
    }
}

// MARK: Decoding

extension CBOR {
    /// Nesting deeper than this is refused rather than recursed into.
    static let maxDepth = 128

    /// Decodes one value that fills `bytes`. Indefinite lengths, truncated input, trailing bytes and
    /// nesting past `maxDepth` throw.
    public static func decode(_ bytes: Data) throws -> CBOR {
        var r = Reader(bytes: [UInt8](bytes))
        let v = try r.value(depth: 0)
        guard r.at == r.bytes.count else { throw CBORError.malformed("trailing bytes after the value") }
        return v
    }

    /// A half-precision float (Float16 is unavailable on Intel Macs).
    static func half(_ h: UInt16) -> Double {
        let sign: Double = h & 0x8000 == 0 ? 1 : -1
        let exp = Int((h >> 10) & 0x1f), frac = Double(h & 0x3ff)
        switch exp {
        case 0: return sign * frac * pow(2, -24)
        case 31: return frac == 0 ? sign * .infinity : .nan
        default: return sign * (1 + frac / 1024) * pow(2, Double(exp - 15))
        }
    }

    private struct Reader {
        let bytes: [UInt8]
        var at = 0

        mutating func byte() throws -> UInt8 {
            guard at < bytes.count else { throw CBORError.malformed("the input ends inside a value") }
            defer { at += 1 }
            return bytes[at]
        }

        mutating func take(_ n: UInt64) throws -> ArraySlice<UInt8> {
            guard n <= UInt64(bytes.count - at) else { throw CBORError.malformed("a length runs past the input") }
            defer { at += Int(n) }
            return bytes[at..<at + Int(n)]
        }

        mutating func uint(_ ai: UInt8) throws -> UInt64 {
            switch ai {
            case 0..<24: return UInt64(ai)
            case 24: return UInt64(try byte())
            case 25: return try take(2).reduce(0) { $0 << 8 | UInt64($1) }
            case 26: return try take(4).reduce(0) { $0 << 8 | UInt64($1) }
            case 27: return try take(8).reduce(0) { $0 << 8 | UInt64($1) }
            case 31: throw CBORError.malformed("indefinite lengths are not supported")
            default: throw CBORError.malformed("reserved additional information \(ai)")
            }
        }

        mutating func value(depth: Int) throws -> CBOR {
            guard depth < CBOR.maxDepth else { throw CBORError.malformed("nesting is deeper than \(CBOR.maxDepth)") }
            let first = try byte()
            let major = first >> 5, ai = first & 0x1f
            switch major {
            case 0: return .unsigned(try uint(ai))
            case 1: return .negative(try uint(ai))
            case 2: return .bytes(Data(try take(try uint(ai))))
            case 3:
                guard let s = String(bytes: try take(try uint(ai)), encoding: .utf8) else {
                    throw CBORError.malformed("text is not UTF-8")
                }
                return .text(s)
            case 4:
                let n = try uint(ai)
                guard n <= UInt64(bytes.count - at) else { throw CBORError.malformed("an array claims more items than the input holds") }
                var items: [CBOR] = []
                items.reserveCapacity(Int(n))
                for _ in 0..<n { items.append(try value(depth: depth + 1)) }
                return .array(items)
            case 5:
                let n = try uint(ai)
                guard n <= UInt64(bytes.count - at) / 2 else { throw CBORError.malformed("a map claims more pairs than the input holds") }
                var pairs: [(CBOR, CBOR)] = []
                pairs.reserveCapacity(Int(n))
                for _ in 0..<n { pairs.append((try value(depth: depth + 1), try value(depth: depth + 1))) }
                return .map(pairs)
            case 6: return .tag(try uint(ai), try value(depth: depth + 1))
            default:
                switch ai {
                case 20: return .bool(false)
                case 21: return .bool(true)
                case 22, 23: return .null
                case 25:
                    let h = try take(2).reduce(UInt16(0)) { $0 << 8 | UInt16($1) }
                    return .double(CBOR.half(h))
                case 26:
                    let f = try take(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                    return .double(Double(Float(bitPattern: f)))
                case 27:
                    return .double(Double(bitPattern: try take(8).reduce(0) { $0 << 8 | UInt64($1) }))
                default: throw CBORError.malformed("unsupported simple value \(ai)")
                }
            }
        }
    }
}
