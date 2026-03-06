import Foundation

enum JSONValue: Sendable, Codable {
    case string(String)
    case number(Double)
    case integer(Int)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var objectValue: [String: JSONValue]? {
        if case let .object(value) = self {
            return value
        }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case let .array(value) = self {
            return value
        }
        return nil
    }

    var stringValue: String? {
        if case let .string(value) = self {
            return value
        }
        return nil
    }

    var intValue: Int? {
        switch self {
        case let .integer(value):
            return value
        case let .number(value):
            return Int(value)
        default:
            return nil
        }
    }

    var boolValue: Bool? {
        if case let .bool(value) = self {
            return value
        }
        return nil
    }
}

extension JSONValue {
    func toFoundationObject() -> Any {
        switch self {
        case let .string(value):
            value
        case let .number(value):
            value
        case let .integer(value):
            value
        case let .bool(value):
            value
        case let .object(value):
            Dictionary(uniqueKeysWithValues: value.map { key, json in
                (key, json.toFoundationObject())
            })
        case let .array(value):
            value.map { $0.toFoundationObject() }
        case .null:
            NSNull()
        }
    }
}

enum JSONValueDecoder {
    static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        let foundation = value.toFoundationObject()
        let data = try JSONSerialization.data(withJSONObject: foundation)
        return try JSONDecoder().decode(type, from: data)
    }
}
