import Foundation
import RetrievalKit
import SemanticRouterKit

/// Why an embedding call failed, in terms the retrieval stage can record.
enum EmbeddingError: LocalizedError, Equatable {
    case notConfigured
    case transport(String)
    case http(status: Int, message: String)
    case malformed(String)
    /// The endpoint returned a width other than the one this provider was built for.
    ///
    /// Fatal rather than tolerated: an index holding two vector widths does not degrade, it
    /// returns confident nonsense — `cosineSimilarity` short-circuits to `0` on a dimension
    /// mismatch, so every stored passage silently scores identically.
    case dimensionMismatch(expected: Int, received: Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No API key, so text cannot be embedded remotely."
        case let .transport(message):
            return "The embeddings endpoint could not be reached: \(message)"
        case let .http(status, message):
            return "The embeddings endpoint returned \(status): \(message)"
        case let .malformed(detail):
            return "The embeddings response could not be read: \(detail)"
        case let .dimensionMismatch(expected, received):
            return "Expected \(expected)-dimension vectors but received \(received)."
        }
    }
}

/// Embeds text with OpenRouter's `/embeddings` endpoint.
///
/// One type conforming to both `RetrievalKit.EmbeddingProvider` and
/// `SemanticRouterKit.RouteEmbedder`, because they are the same two members under two names and
/// the alternative is two objects issuing the same request against the same key.
///
/// **This never falls back to the hashing embedder, and that is deliberate.** The bundled
/// `HashingEmbeddingProvider` produces a different, smaller vector width. A per-call fallback
/// would put two widths into one index, and `cosineSimilarity` returns `0` for a dimension
/// mismatch rather than throwing — so a store that had silently mixed them would rank every
/// passage equally and look like it was merely retrieving badly. Which embedder is in use is
/// therefore decided once, at composition, from whether a key exists; a failure here throws and
/// the retrieval stage records it, which is a fact the Diagnostics screen can show.
struct OpenRouterEmbeddingProvider: EmbeddingProvider, RouteEmbedder {
    /// `text-embedding-3-small` at its native width. Cheap, and the smallest of the hosted options
    /// — retrieval over a chat transcript is not the workload that justifies 3072 floats a passage.
    static let defaultModel = "openai/text-embedding-3-small"
    static let defaultDimension = 1_536

    let dimension: Int

    private let configuration: OpenRouterConfiguration
    private let model: String
    private let session: URLSession

    init(
        configuration: OpenRouterConfiguration,
        model: String = OpenRouterEmbeddingProvider.defaultModel,
        dimension: Int = OpenRouterEmbeddingProvider.defaultDimension,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.model = model
        self.dimension = dimension
        self.session = session
    }

    /// True when a key is present. The composition root asks this rather than guessing, because an
    /// unconfigured provider that throws on every call is worse than the hashing one that works.
    static func isUsable(_ configuration: OpenRouterConfiguration) -> Bool {
        !configuration.apiKey.isEmpty
    }

    func embed(_ text: String) async throws -> Embedding {
        Embedding(vector: try await vector(for: text))
    }

    /// `RouteEmbedder`'s half. Same request, different wrapper.
    func embed(_ text: String) async throws -> RouteVector {
        RouteVector(values: try await vector(for: text))
    }

    private func vector(for text: String) async throws -> [Double] {
        guard Self.isUsable(configuration) else { throw EmbeddingError.notConfigured }

        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("embeddings"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        // `input` is sent as a single string rather than a one-element array: the endpoint accepts
        // both, and the scalar form is what every provider behind it documents, so it is the shape
        // least likely to be mishandled by whichever one OpenRouter routes to.
        request.httpBody = try JSONEncoder().encode(EmbeddingRequestBody(model: model, input: text))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw EmbeddingError.transport(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = String(data: data, encoding: .utf8) ?? "no body"
            throw EmbeddingError.http(status: http.statusCode, message: message)
        }

        let decoded: EmbeddingResponseBody
        do {
            decoded = try JSONDecoder().decode(EmbeddingResponseBody.self, from: data)
        } catch {
            throw EmbeddingError.malformed(error.localizedDescription)
        }
        guard let first = decoded.data.first else {
            throw EmbeddingError.malformed("the response carried no embeddings")
        }
        guard first.embedding.count == dimension else {
            throw EmbeddingError.dimensionMismatch(
                expected: dimension,
                received: first.embedding.count
            )
        }
        return first.embedding
    }
}

// MARK: - Wire types

/// Named with an `Embedding` prefix throughout, following this app's habit of renaming wire types
/// to stay clear of package symbols.
private struct EmbeddingRequestBody: Encodable {
    let model: String
    let input: String
}

private struct EmbeddingResponseBody: Decodable {
    struct Item: Decodable {
        let embedding: [Double]
    }

    let data: [Item]
}
