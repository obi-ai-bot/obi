import Foundation

/// Any JSON value: what MCP's JSON-RPC carries and what the runner answers, read without a type
/// for every object, since oby-mcp passes most of it on as text.
enum JSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    subscript(key: String) -> JSON? {
        if case .object(let object) = self { object[key] } else { nil }
    }

    var string: String? {
        if case .string(let string) = self { string } else { nil }
    }

    var number: Double? {
        if case .number(let number) = self { number } else { nil }
    }

    var int: Int? {
        number.flatMap { $0.rounded() == $0 && abs($0) < 9e15 ? Int($0) : nil }
    }

    var bool: Bool? {
        if case .bool(let bool) = self { bool } else { nil }
    }

    var array: [JSON]? {
        if case .array(let array) = self { array } else { nil }
    }

    var object: [String: JSON]? {
        if case .object(let object) = self { object } else { nil }
    }

    var isNull: Bool { self == .null }

    /// A string, or a number written as one: what a key holds, for a line of text.
    var text: String? {
        switch self {
        case .string(let string): string
        case .number: int.map(String.init) ?? number.map { String($0) }
        case .bool(let bool): bool ? "yes" : "no"
        default: nil
        }
    }

    static func parse(_ data: Data) throws -> JSON {
        try JSONDecoder().decode(JSON.self, from: data)
    }

    /// Written out compactly, keys sorted, as one line (JSON-RPC over stdio is a line per message).
    var data: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }

    var line: String { String(decoding: data, as: UTF8.self) }
}

extension JSON: Codable {
    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            self = .null
        } else if let bool = try? value.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? value.decode(Double.self) {
            self = .number(number)
        } else if let string = try? value.decode(String.self) {
            self = .string(string)
        } else if let array = try? value.decode([JSON].self) {
            self = .array(array)
        } else {
            self = .object(try value.decode([String: JSON].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let bool): try value.encode(bool)
        // A JSON-RPC id of 1 goes back as 1, not 1.0.
        case .number(let number): if let int { try value.encode(int) } else { try value.encode(number) }
        case .string(let string): try value.encode(string)
        case .array(let array): try value.encode(array)
        case .object(let object): try value.encode(object)
        }
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral,
                ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSON...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSON)...) { self = .object(Dictionary(elements, uniquingKeysWith: { $1 })) }
    init(nilLiteral: ()) { self = .null }
}
