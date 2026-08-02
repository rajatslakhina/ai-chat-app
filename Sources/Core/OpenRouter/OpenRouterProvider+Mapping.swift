import Foundation
import ProviderGatewayKit
import StreamAggregatorKit

/// Turning what OpenRouter sent into what the gateway understands.
extension OpenRouterProvider {
    /// Turns a decoded response into the one event the gateway cares about.
    static func outcome(from response: OpenRouterChatResponse) throws -> Outcome {
        guard let choice = response.choices.first else {
            throw ProviderError.connectionFailed("response contained no choices")
        }

        if let call = choice.message?.toolCalls?.first, let function = call.function,
           let name = function.name {
            return .toolCall(
                ToolCallRequest(
                    id: call.id ?? UUID().uuidString,
                    toolName: name,
                    arguments: decodeArguments(function.arguments)
                )
            )
        }

        let text = choice.message?.content ?? ""
        return .text(text, finishReason(for: choice.finishReason))
    }

    /// Parses the tool-argument JSON *string* models emit.
    ///
    /// Returns empty rather than throwing on malformed JSON. A model emitting broken argument
    /// JSON is a normal failure mode, and the right place to handle it is the tool layer — which
    /// can report "you called me with nothing" back into the conversation — not the transport,
    /// which would turn it into a dead request and trip the circuit breaker on the provider's
    /// behalf for something the provider did not do wrong.
    static func decodeArguments(_ raw: String?) -> [String: LLMToolArgumentValue] {
        guard let raw, let data = raw.data(using: .utf8) else { return [:] }
        guard let decoded = try? JSONDecoder().decode(OpenRouterJSON.self, from: data),
              case let .object(fields) = decoded else { return [:] }
        return fields.mapValues(\.asToolArgument)
    }

    static func finishReason(for raw: String?) -> LLMResponse.FinishReason {
        switch raw {
        case "length": return .maxTokens
        default: return .stop
        }
    }

    /// Maps transport failures onto the gateway's error model.
    ///
    /// This mapping is what makes the router's circuit breaker behave. A 429 must arrive as
    /// `.rateLimited` so the breaker can back off rather than hammering, and a genuinely dead
    /// host must arrive as `.connectionFailed` so it can be taken out of rotation. Collapsing
    /// both into one error would make "slow down" and "this backend is gone" indistinguishable.
    static func providerError(for error: URLError) -> ProviderError {
        switch error.code {
        case .timedOut:
            return .timeout
        case .cancelled:
            return .connectionFailed("request was cancelled")
        default:
            return .connectionFailed(error.localizedDescription)
        }
    }

    static func providerError(status: Int, headers: HTTPURLResponse, body: Data) -> ProviderError {
        let message = (try? JSONDecoder().decode(OpenRouterErrorEnvelope.self, from: body))?
            .error?.message ?? String(data: body, encoding: .utf8) ?? "no error body"

        switch status {
        case 429:
            return .rateLimited(retryAfter: retryAfter(from: headers))
        case 401, 403:
            return .capabilityMismatch(
                "OpenRouter rejected the API key (HTTP \(status)): \(message)"
            )
        case 402:
            return .capabilityMismatch("OpenRouter account is out of credit: \(message)")
        case 408, 504:
            return .timeout
        default:
            return .connectionFailed("HTTP \(status): \(message)")
        }
    }

    /// `Retry-After` is seconds or an HTTP date. Only the seconds form is honoured; a date is
    /// treated as absent rather than guessed at, because a wrong backoff is worse than none.
    static func retryAfter(from response: HTTPURLResponse) -> Duration? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        guard let seconds = Int(raw.trimmingCharacters(in: .whitespaces)), seconds >= 0 else {
            return nil
        }
        return .seconds(seconds)
    }
}
