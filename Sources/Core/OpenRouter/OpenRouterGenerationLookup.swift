import Foundation
import UsageRecoveryKit

/// Asks OpenRouter what one generation was billed: `GET /api/v1/generation?id=`.
///
/// The record is written after the stream ends, so a lookup made straight away can answer 404 for
/// an id that is real; that is `.notYetAvailable`, and `UsageRecovery` asks again on its schedule.
/// Any other failure throws, which is also retried. Token counts prefer the `native_tokens_*`
/// fields, the upstream's own counts, over OpenRouter's normalized `tokens_*`; `total_cost` is
/// what was charged.
struct OpenRouterGenerationLookup: GenerationLookup {
    let configuration: OpenRouterConfiguration
    let session: URLSession

    struct Failure: Error, CustomStringConvertible {
        let status: Int
        var description: String { "the generation lookup answered HTTP \(status)" }
    }

    func lookUp(_ id: GenerationID) async throws -> LookupAnswer {
        let (data, response) = try await session.data(for: request(for: id))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            return .billed(try Self.usage(from: data))
        case 404:
            return .notYetAvailable
        default:
            throw Failure(status: status)
        }
    }

    /// A `GenerationID` holds only characters a query string carries as they are, so nothing here can fail.
    func request(for id: GenerationID) -> URLRequest {
        let url = configuration.baseURL
            .appendingPathComponent("generation")
            .appending(queryItems: [URLQueryItem(name: "id", value: id.rawValue)])
        var request = URLRequest(url: url)
        request.timeoutInterval = configuration.timeout
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func usage(from data: Data) throws -> BilledUsage {
        let record = try JSONDecoder().decode(Envelope.self, from: data).data
        return try BilledUsage(
            inputTokens: record.nativeTokensPrompt ?? record.tokensPrompt ?? 0,
            outputTokens: record.nativeTokensCompletion ?? record.tokensCompletion ?? 0,
            microcents: record.totalCost.map { Int(($0 * 100_000_000).rounded()) },
            cancelled: record.cancelled,
            upstreamProvider: record.providerName
        )
    }

    private struct Envelope: Decodable {
        let data: Generation
    }

    private struct Generation: Decodable {
        let tokensPrompt: Int?
        let tokensCompletion: Int?
        let nativeTokensPrompt: Int?
        let nativeTokensCompletion: Int?
        let totalCost: Double?
        let cancelled: Bool?
        let providerName: String?

        enum CodingKeys: String, CodingKey {
            case tokensPrompt = "tokens_prompt"
            case tokensCompletion = "tokens_completion"
            case nativeTokensPrompt = "native_tokens_prompt"
            case nativeTokensCompletion = "native_tokens_completion"
            case totalCost = "total_cost"
            case cancelled
            case providerName = "provider_name"
        }
    }
}
