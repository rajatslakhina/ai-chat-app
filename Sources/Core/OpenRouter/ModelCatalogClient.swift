import Foundation
import ProviderGatewayKit

/// Fetches the model catalog and the key's own status.
///
/// Separate from `OpenRouterProvider` on purpose: the provider is on the hot path of every turn
/// and conforms to a protocol that knows nothing about catalogs. Folding catalog fetching into it
/// would put a second responsibility behind `LLMProvider` and make the provider untestable
/// without also stubbing the catalog.
struct ModelCatalogClient: Sendable {
    private let configuration: OpenRouterConfiguration
    private let session: URLSession

    init(configuration: OpenRouterConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    /// `GET /api/v1/models`.
    ///
    /// Unauthenticated in principle, but the key is sent when present so the response reflects
    /// what this account can actually reach.
    func fetchCatalog() async throws -> ModelCatalog {
        let response: OpenRouterModel.Response = try await get("models")
        return ModelCatalog(models: response.data)
    }

    /// `GET /api/v1/key` — what this key is allowed to spend.
    func fetchKeyStatus() async throws -> OpenRouterKeyStatus {
        let response: OpenRouterKeyStatus.Envelope = try await get("key")
        return response.data
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent(path))
        request.httpMethod = "GET"
        request.timeoutInterval = configuration.timeout
        if !configuration.apiKey.isEmpty {
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw OpenRouterProvider.providerError(for: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.connectionFailed("response was not HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenRouterProvider.providerError(
                status: http.statusCode,
                headers: http,
                body: data
            )
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ProviderError.connectionFailed("could not decode \(path): \(error)")
        }
    }
}

/// What `GET /api/v1/key` reports.
///
/// `limit` and `limitRemaining` are `number | null`, and **null means no limit rather than zero**.
/// Modelling them as `Int` with a zero default would show a funded account as being out of credit,
/// and computing `limit - usage` on a null limit is meaningless. Both stay optional, and the
/// display logic below is the only place that decides what absent means.
struct OpenRouterKeyStatus: Decodable, Equatable, Sendable {
    let label: String?
    let usage: Double?
    let limit: Double?
    let limitRemaining: Double?
    let isFreeTier: Bool?

    enum CodingKeys: String, CodingKey {
        case label, usage, limit
        case limitRemaining = "limit_remaining"
        case isFreeTier = "is_free_tier"
    }

    struct Envelope: Decodable, Equatable, Sendable {
        let data: OpenRouterKeyStatus
    }

    /// True only when a limit exists and has been reached. An absent limit is unlimited, so it can
    /// never be exhausted.
    var isExhausted: Bool {
        guard let remaining = limitRemaining else { return false }
        return remaining <= 0
    }

    /// What Settings shows for remaining credit.
    var remainingDescription: String {
        guard limit != nil else { return "Unlimited" }
        guard let remaining = limitRemaining else { return "Unknown" }
        return String(format: "$%.4f", remaining)
    }
}
