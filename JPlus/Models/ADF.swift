import Foundation

/// A loosely-typed JSON value, used for ADF node/mark attributes.
enum JSONValue: Decodable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .number(let value): return value == value.rounded() ? String(Int(value)) : String(value)
        case .bool(let value): return String(value)
        default: return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .number(let value): return Int(value)
        case .string(let value): return Int(value)
        default: return nil
        }
    }
}

/// Atlassian Document Format node. Descriptions and comments in the v3 API
/// are ADF trees rather than wiki markup.
struct ADFNode: Decodable, Hashable, Sendable {
    let type: String
    let text: String?
    let attrs: [String: JSONValue]?
    let marks: [ADFMark]?
    let content: [ADFNode]?

    func attr(_ name: String) -> String? { attrs?[name]?.stringValue }
    func intAttr(_ name: String) -> Int? { attrs?[name]?.intValue }

    var children: [ADFNode] { content ?? [] }

    /// Plain-text projection, useful for previews and fallbacks.
    var plainText: String {
        if type == "text" { return text ?? "" }
        if type == "hardBreak" { return "\n" }
        if type == "mention" || type == "emoji" { return attr("text") ?? "" }
        let inner = children.map(\.plainText)
        switch type {
        case "paragraph", "heading", "listItem", "codeBlock", "blockquote":
            return inner.joined() + "\n"
        default:
            return inner.joined()
        }
    }
}

struct ADFMark: Decodable, Hashable, Sendable {
    let type: String
    let attrs: [String: JSONValue]?

    func attr(_ name: String) -> String? { attrs?[name]?.stringValue }
}
