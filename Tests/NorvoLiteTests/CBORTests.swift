import Foundation
import Testing
@testable import NorvoLite

struct Row: Codable, Equatable {
    let id: UUID
    let at: Date
    let blob: Data
    let vec: [Float]
    let n: Int
    let x: Double
    let ok: Bool
    let s: String?
    let json: JSONValue
}

@Test func valuesRoundTripThroughBytes() throws {
    let values: [CBOR] = [
        .unsigned(0), .unsigned(23), .unsigned(24), .unsigned(1 << 40), .negative(0), .negative(1 << 33),
        .bytes(Data([1, 2])), .text("ü€𝄞"), .array([.null, .bool(true)]),
        .map([(.text("b"), .unsigned(1)), (.text("a"), .unsigned(2))]),
        .tag(37, .bytes(Data(repeating: 7, count: 16))), .double(1.5), .double(-0.0),
    ]
    for v in values {
        #expect(try CBOR.decode(v.encoded()) == v)
    }
}

@Test func decodableRowsUseLitesTags() throws {
    let id = UUID()
    let row = Row(
        id: id, at: Date(timeIntervalSince1970: 1_700_000_000.25), blob: Data([9]),
        vec: [1, -2.5], n: -7, x: 3.25, ok: true, s: nil,
        json: .object(["k": .array([.int(1), .string("v"), .null])])
    )
    let cbor = try CBOREncoder().encode(row)
    #expect(cbor["id"] == .tag(37, .bytes(withUnsafeBytes(of: id.uuid) { Data($0) })))
    #expect(cbor["at"] == .tag(1001, .map([(.unsigned(1), .unsigned(1_700_000_000)), (.negative(2), .unsigned(250))])))
    #expect(cbor["vec"] == .tag(85, .bytes(Data([0, 0, 128, 63, 0, 0, 32, 192]))))
    #expect(cbor["s"] == nil, "nil optionals are left out")
    #expect(try CBORDecoder().decode(Row.self, from: cbor) == row)
    // Tag 1 (whole seconds) decodes as a Date too.
    #expect(try CBORDecoder().decode(Date.self, from: .tag(1, .unsigned(5))) == Date(timeIntervalSince1970: 5))
}

@Test func hostileInputThrows() {
    #expect(throws: (any Error).self) { try CBOR.decode(Data([0x9f])) }            // indefinite length
    #expect(throws: (any Error).self) { try CBOR.decode(Data([0x5b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff])) }
    #expect(throws: (any Error).self) { try CBOR.decode(Data(repeating: 0x81, count: 10_000)) } // too deep
}
