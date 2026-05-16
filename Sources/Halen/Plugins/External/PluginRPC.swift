import Foundation

/// JSON-RPC 2.0 framing for the out-of-process plugin protocol. Newline-
/// delimited UTF-8 over the plugin's stdio:
///
///   * **stdin**  — host writes requests + notifications to the plugin
///   * **stdout** — plugin writes responses + its own requests/notifications
///   * **stderr** — plugin's freeform log channel (host forwards to `Log`)
///
/// Framing is NDJSON, **not** LSP's Content-Length headers: one JSON message
/// per line, no embedded raw newlines (JSON encoders escape them as `\n`).
/// Same shape Anthropic's MCP picked — easier to debug with `cat`/`jq`, easier
/// to implement in any language a plugin author might pick.
enum PluginRPC {
    /// Halen-specific error codes occupy the JSON-RPC reserved
    /// implementation-defined range `[-32099, -32000]`. Standard JSON-RPC
    /// codes (parse error, invalid params, method not found, etc.) keep
    /// their canonical values.
    enum ErrorCode: Int {
        case parseError       = -32700
        case invalidRequest   = -32600
        case methodNotFound   = -32601
        case invalidParams    = -32602
        case internalError    = -32603
        // LSP-borrowed
        case requestCancelled = -32800
        // Halen-specific
        case permissionDenied   = -32001
        case inferenceUnavailable = -32002
        case axWriteFailed      = -32003
    }
}

/// A single JSON-RPC 2.0 message. Decoded from any incoming line; we figure
/// out which subtype it is from the `id`/`method`/`result`/`error` shape.
struct RPCMessage: Codable {
    let jsonrpc: String
    let id: RPCId?
    let method: String?
    let params: RPCValue?
    let result: RPCValue?
    let error: RPCErrorObject?

    init(jsonrpc: String = "2.0",
         id: RPCId? = nil,
         method: String? = nil,
         params: RPCValue? = nil,
         result: RPCValue? = nil,
         error: RPCErrorObject? = nil) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
        self.result = result
        self.error = error
    }

    /// `true` when this is a request expecting a response (has both `method`
    /// and `id`). Notifications have a `method` but no `id`.
    var isRequest: Bool { method != nil && id != nil }
    var isNotification: Bool { method != nil && id == nil }
    var isResponse: Bool { method == nil && id != nil }
}

/// JSON-RPC `id` is `string | number | null` per spec; we restrict to
/// integers because Halen never needs the others.
enum RPCId: Codable, Hashable {
    case number(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self)       { self = .number(i); return }
        if let s = try? c.decode(String.self)    { self = .string(s); return }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "RPC id must be int or string")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let i): try c.encode(i)
        case .string(let s): try c.encode(s)
        }
    }
}

struct RPCErrorObject: Codable, Error, LocalizedError {
    let code: Int
    let message: String
    let data: RPCValue?

    var errorDescription: String? { "RPC error \(code): \(message)" }
}

/// Type-erased JSON value. `JSONSerialization` would be more elegant but we
/// need Codable conformance so the surrounding `RPCMessage` round-trips.
indirect enum RPCValue: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([RPCValue])
    case object([String: RPCValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil()                                     { self = .null; return }
        if let v = try? c.decode(Bool.self)                  { self = .bool(v); return }
        if let v = try? c.decode(Int.self)                   { self = .int(v); return }
        if let v = try? c.decode(Double.self)                { self = .double(v); return }
        if let v = try? c.decode(String.self)                { self = .string(v); return }
        if let v = try? c.decode([RPCValue].self)            { self = .array(v); return }
        if let v = try? c.decode([String: RPCValue].self)    { self = .object(v); return }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "Unexpected JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:          try c.encodeNil()
        case .bool(let v):   try c.encode(v)
        case .int(let v):    try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v):  try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    // MARK: - Convenience accessors used by the bridge

    var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    var intValue: Int?       { if case .int(let i) = self { return i } else { return nil } }
    var objectValue: [String: RPCValue]? { if case .object(let o) = self { return o } else { return nil } }
    var arrayValue: [RPCValue]?         { if case .array(let a) = self { return a } else { return nil } }

    /// Builds an `.object` literal from a `[String: Any]`-shaped dictionary —
    /// the natural Swift call site for constructing params/results.
    static func object(_ pairs: [String: Any?]) -> RPCValue {
        var out: [String: RPCValue] = [:]
        for (k, v) in pairs { out[k] = from(v) }
        return .object(out)
    }

    /// Best-effort coercion from a Swift any-value into an `RPCValue`.
    static func from(_ value: Any?) -> RPCValue {
        switch value {
        case .none:                  return .null
        case let v as Bool:          return .bool(v)
        case let v as Int:           return .int(v)
        case let v as Int64:         return .int(Int(v))
        case let v as Double:        return .double(v)
        case let v as String:        return .string(v)
        case let v as RPCValue:      return v
        case let v as [Any?]:        return .array(v.map(from))
        case let v as [String: Any?]:
            var out: [String: RPCValue] = [:]
            for (k, x) in v { out[k] = from(x) }
            return .object(out)
        default: return .null
        }
    }
}
