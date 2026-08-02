import Foundation
import StreamAggregatorKit

/// One `chat.completion.chunk` frame.
///
/// Modelled from a captured stream. Everything is optional because the chunks genuinely differ
/// from one another: the first carries a role, the middle ones carry content, one carries a
/// finish reason, and a final one carries usage — and a keep-alive carries nothing at all.
struct OpenRouterStreamChunk: Decodable, Equatable {
    let id: String?
    let model: String?
    let choices: [Choice]?
    let usage: Usage?

    struct Choice: Decodable, Equatable {
        let index: Int?
        let delta: Delta?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case index, delta
            case finishReason = "finish_reason"
        }

        struct Delta: Decodable, Equatable {
            let role: String?
            let content: String?
            let toolCalls: [ToolCallFragment]?

            enum CodingKeys: String, CodingKey {
                case role, content
                case toolCalls = "tool_calls"
            }
        }

        /// A partial tool call.
        ///
        /// `index` is the identity that matters: a provider dribbles one call's arguments across
        /// many frames, and only the first frame for an index carries `id` and `name`. Merging on
        /// anything else — position in the array, or `id`, which is nil on most frames — corrupts
        /// concurrent tool calls into one.
        struct ToolCallFragment: Decodable, Equatable {
            let index: Int?
            let id: String?
            let function: Function?

            struct Function: Decodable, Equatable {
                let name: String?
                let arguments: String?
            }
        }
    }

    struct Usage: Decodable, Equatable {
        let promptTokens: Int?
        let completionTokens: Int?
        let cost: Double?
        let promptTokensDetails: Details?

        enum CodingKeys: String, CodingKey {
            case cost
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case promptTokensDetails = "prompt_tokens_details"
        }

        struct Details: Decodable, Equatable {
            let cachedTokens: Int?

            enum CodingKeys: String, CodingKey {
                case cachedTokens = "cached_tokens"
            }
        }
    }
}

extension OpenRouterStreamChunk {
    /// Maps this chunk onto StreamAggregatorKit's normalized delta vocabulary.
    ///
    /// One chunk can produce several deltas — a first frame typically carries both a role and a
    /// content fragment — so this returns an array rather than an optional.
    var streamDeltas: [StreamDelta] {
        var deltas: [StreamDelta] = []
        if let choice = choices?.first {
            if let role = choice.delta?.role, !role.isEmpty {
                deltas.append(.role(role))
            }
            if let content = choice.delta?.content, !content.isEmpty {
                deltas.append(.content(content))
            }
            for fragment in choice.delta?.toolCalls ?? [] {
                deltas.append(
                    .toolCall(
                        index: fragment.index ?? 0,
                        id: fragment.id,
                        name: fragment.function?.name,
                        argumentsFragment: fragment.function?.arguments ?? ""
                    )
                )
            }
            if let raw = choice.finishReason {
                deltas.append(.finish(FinishReason.from(raw)))
            }
        }
        if let usage {
            deltas.append(
                .usage(
                    promptTokens: usage.promptTokens ?? 0,
                    completionTokens: usage.completionTokens ?? 0
                )
            )
        }
        return deltas
    }

    /// The richer accounting StreamAggregatorKit's `TokenUsage` does not model.
    ///
    /// `StreamDelta.usage` carries prompt and completion tokens only — correct for a portable
    /// aggregator, insufficient for showing what a turn cost. Cached-prompt tokens and
    /// OpenRouter's own reported charge come out here instead of being re-derived.
    func openRouterUsage(fallbackModel: String) -> OpenRouterUsage? {
        guard let usage else { return nil }
        return OpenRouterUsage(
            requestID: id,
            model: model ?? fallbackModel,
            promptTokens: usage.promptTokens ?? 0,
            completionTokens: usage.completionTokens ?? 0,
            cachedPromptTokens: usage.promptTokensDetails?.cachedTokens ?? 0,
            reportedCostUSD: usage.cost
        )
    }
}
