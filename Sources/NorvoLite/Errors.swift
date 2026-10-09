import CNorvoLite
import Foundation

/// A call that failed: Lite's status, its message, the position in the operation text when the error is
/// about it, and a suggested fix.
public struct NorvoError: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Code: Int32, Sendable {
        case syntax = 2
        case invalid, constraint, notFound, migration, tooCostly, locked, io, corrupt, fatal, `internal`,
            pending, busy, aborted

        /// The code of a response error's `extensions.code`.
        init(responseCode: String?) {
            self =
                switch responseCode {
                case "INVALID": .invalid
                case "CONSTRAINT": .constraint
                case "NOT_FOUND": .notFound
                case "TOO_COSTLY": .tooCostly
                case "PENDING": .pending
                case "MIGRATION": .migration
                case "CORRUPT": .corrupt
                case "IO": .io
                case "FATAL": .fatal
                default: .internal
                }
        }
    }

    public let code: Code
    public let message: String
    /// 1-based; 0 when the error is not about the operation text.
    public let line: Int
    public let column: Int
    public let hint: String?

    public init(code: Code, message: String, line: Int = 0, column: Int = 0, hint: String? = nil) {
        self.code = code
        self.message = message
        self.line = line
        self.column = column
        self.hint = hint
    }

    public var description: String {
        var s = line > 0 ? "\(line):\(column): \(message)" : message
        if let hint { s += " (hint: \(hint))" }
        return s
    }

    /// Reads and frees a `norvo_error`, for a call that returned `status`.
    static func take(_ err: OpaquePointer?, status: Int32) -> NorvoError {
        guard let err else {
            return NorvoError(code: Code(rawValue: status) ?? .internal, message: "Lite returned status \(status)")
        }
        defer { norvo_error_free(err) }
        return NorvoError(
            code: Code(rawValue: norvo_error_code(err)) ?? .internal,
            message: String(cString: norvo_error_message(err)),
            line: Int(norvo_error_line(err)),
            column: Int(norvo_error_column(err)),
            hint: norvo_error_hint(err).map { String(cString: $0) }
        )
    }
}

/// One error of a response, as GraphQL reports it.
public struct GraphQLError: Sendable, Equatable, Decodable {
    public let message: String
    public let path: [PathItem]
    /// `extensions.code`: `INVALID`, `CONSTRAINT`, `NOT_FOUND`, ...
    public let code: String?

    private enum CodingKeys: String, CodingKey { case message, path, extensions }
    private enum ExtensionKeys: String, CodingKey { case code }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        message = try c.decode(String.self, forKey: .message)
        path = try c.decodeIfPresent([PathItem].self, forKey: .path) ?? []
        code = try c.decodeIfPresent([String: String].self, forKey: .extensions)?["code"]
    }
}

/// One step of a response path.
public enum PathItem: Sendable, Equatable, Decodable {
    case key(String)
    case index(Int)

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) {
            self = .index(i)
        } else {
            self = .key(try c.decode(String.self))
        }
    }
}

/// A response that carries errors. A query's `partial` holds the data the response still has (nil when a
/// null reached `data`); a mutation has none, since its first error rolls it back.
public struct ResponseError<D: Sendable>: Error, Sendable {
    public let errors: [GraphQLError]
    public let partial: D?
}
