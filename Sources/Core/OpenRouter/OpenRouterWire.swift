import Foundation
import ProviderGatewayKit

// MARK: - Request

/// The body POSTed to `/api/v1/chat/completions`.
///
/// Only the fields this app actually sends are modelled. OpenRouter accepts many more, and
/// encoding an optional as `null` is not the same as omitting it for some of them, so every
/// optional here is genuinely omitted when nil rather than encoded as null.
struct OpenRouterChatRequest: Encodable, Equatable {
    let model: String
    let messages: [Message]
    let temperature: Double
    let maxTokens: Int
    let stream: Bool
    let tools: [Tool]?
    let usage: UsageOption?

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stream, tools, usage
        case maxTokens = "max_tokens"
    }

    /// Asks OpenRouter to include real accounting in the response.
    ///
    /// Without this the response carries token counts but not the credit cost OpenRouter
    /// actually charged. Deriving cost from a local price table instead would drift the moment
    /// a model's price changes upstream.
    struct UsageOption: Encodable, Equatable {
        let include: Bool
    }

    struct Message: Encodable, Equatable {
        let role: String
        let content: String
        let toolCallID: String?

        enum CodingKeys: String, CodingKey {
            case role, content
            case toolCallID = "tool_call_id"
        }
    }

    struct Tool: Encodable, Equatable {
        let type = "function"
        let function: Function

        enum CodingKeys: String, CodingKey { case type, function }

        struct Function: Encodable, Equatable {
            let name: String
            let description: String
            let parameters: OpenRouterJSON
        }
    }
}

// MARK: - Response

/// The non-streaming response body.
///
/// Every field beyond `choices` is optional because OpenRouter proxies many upstream providers
/// and they do not all populate the same envelope. Making `usage` non-optional here would turn
/// a provider that omits it into a decode failure, i.e. a total request failure over accounting.
struct OpenRouterChatResponse: Decodable, Equatable {
    let id: String?
    let model: String?
    let choices: [Choice]
    let usage: Usage?

    struct Choice: Decodable, Equatable {
        let message: Message?
        let finishReason: String?
        let nativeFinishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
            case nativeFinishReason = "native_finish_reason"
        }

        struct Message: Decodable, Equatable {
            let role: String?
            let content: String?
            let toolCalls: [ToolCall]?

            enum CodingKeys: String, CodingKey {
                case role, content
                case toolCalls = "tool_calls"
            }
        }

        struct ToolCall: Decodable, Equatable {
            let id: String?
            let type: String?
            let function: Function?

            struct Function: Decodable, Equatable {
                let name: String?
                /// A JSON *string*, not a JSON object. The model emits arguments as serialized
                /// text, so this needs a second parse — and that parse can fail on a model that
                /// emits malformed JSON, which is a normal occurrence rather than an anomaly.
                let arguments: String?
            }
        }
    }

    struct Usage: Decodable, Equatable {
        let promptTokens: Int?
        let completionTokens: Int?
        let totalTokens: Int?
        let cost: Double?
        let promptTokensDetails: PromptDetails?

        enum CodingKeys: String, CodingKey {
            case cost
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
            case promptTokensDetails = "prompt_tokens_details"
        }

        struct PromptDetails: Decodable, Equatable {
            let cachedTokens: Int?

            enum CodingKeys: String, CodingKey {
                case cachedTokens = "cached_tokens"
            }
        }
    }
}

/// The error envelope OpenRouter returns on a non-2xx status.
struct OpenRouterErrorEnvelope: Decodable, Equatable {
    let error: Payload?

    struct Payload: Decodable, Equatable {
        let message: String?
        let code: Int?
        let type: String?
    }
}

// MARK: - JSON bridging

/// A JSON value that is `Sendable`, `Equatable` and round-trippable.
///
/// `[String: Any]` would be shorter and would also break `Sendable` the moment a tool schema
/// crossed an actor boundary, which is exactly what happens between this provider and the
/// router. `LLMToolArgumentValue` in ProviderGatewayKit exists for the same reason; this is its
/// `Codable` counterpart, and the two convert to each other below.
indirect enum OpenRouterJSON: Codable, Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([OpenRouterJSON])
    case object([String: OpenRouterJSON])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([OpenRouterJSON].self) {
            self = .array(value)
        } else {
            // The last case rather than another `else if`: the seven cases above cover every
            // value JSON can express, so a trailing `throw` here would be unreachable code that
            // no test could ever close. If this decode fails the input was not JSON at all, and
            // `JSONDecoder` has already rejected it before reaching this initializer.
            self = .object(try container.decode([String: OpenRouterJSON].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

extension OpenRouterJSON {
    /// Converts a gateway tool-argument value into its wire form.
    init(_ value: LLMToolArgumentValue) {
        switch value {
        case .string(let inner): self = .string(inner)
        case .int(let inner): self = .int(inner)
        case .double(let inner): self = .double(inner)
        case .bool(let inner): self = .bool(inner)
        case .array(let inner): self = .array(inner.map(OpenRouterJSON.init))
        case .object(let inner): self = .object(inner.mapValues(OpenRouterJSON.init))
        case .null: self = .null
        }
    }

    /// Converts back into the gateway's argument model for `ToolCallRequest`.
    var asToolArgument: LLMToolArgumentValue {
        switch self {
        case .string(let inner): return .string(inner)
        case .int(let inner): return .int(inner)
        case .double(let inner): return .double(inner)
        case .bool(let inner): return .bool(inner)
        case .array(let inner): return .array(inner.map(\.asToolArgument))
        case .object(let inner): return .object(inner.mapValues(\.asToolArgument))
        case .null: return .null
        }
    }
}

extension OpenRouterChatRequest.Tool {
    /// Renders a gateway tool definition as an OpenAI-style function schema.
    ///
    /// A tool declared with no parameters still needs a schema object — `{"type":"object",
    /// "properties":{}}` — because several upstream providers reject a function whose
    /// `parameters` is absent or null.
    init(_ definition: LLMToolDefinition) {
        self.function = Function(
            name: definition.name,
            description: definition.toolDescription,
            parameters: Self.parameters(from: definition.parameterSchema.mapValues(OpenRouterJSON.init))
        )
    }

    /// `LLMToolDefinition.parameterSchema` is a loose `[String: LLMToolArgumentValue]` that this
    /// app uses in two different ways, and the difference matters on the wire.
    ///
    /// A definition bridged from `ToolRegistryKit` carries the *complete* JSON Schema object,
    /// `required` list and all — so it is sent through untouched, because inferring `required`
    /// from the property names would make every optional argument mandatory and turn an
    /// argument-less call into a schema violation. Anything else is a bare property map and is
    /// wrapped, which is the shape the gateway's own simulated tools declare.
    static func parameters(from schema: [String: OpenRouterJSON]) -> OpenRouterJSON {
        if case .string("object")? = schema["type"] {
            return .object(schema)
        }
        return .object([
            "type": .string("object"),
            "properties": .object(schema),
            "required": .array(schema.keys.sorted().map(OpenRouterJSON.string))
        ])
    }
}

extension OpenRouterChatRequest.Message {
    /// Maps a gateway message onto the wire.
    ///
    /// `tool_call_id` is sent only on `.tool` messages; including it on any other role is a
    /// 400 from several upstreams.
    init(_ message: LLMMessage) {
        self.role = message.role.rawValue
        self.content = message.content
        self.toolCallID = message.role == .tool ? message.toolCallID : nil
    }
}
