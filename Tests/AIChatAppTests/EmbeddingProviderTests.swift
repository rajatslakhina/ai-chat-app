import Foundation
import RetrievalKit
import SemanticRouterKit
import Testing
@testable import AIChatApp

/// The hosted embedder, and the one decision that keeps a vector store honest.
///
/// `.serialized` for the usual reason: `StubURLProtocol`'s queue is static.
@Suite("OpenRouter embeddings", .serialized)
struct EmbeddingProviderTests {
    private static let dimension = 4

    private func provider() -> OpenRouterEmbeddingProvider {
        OpenRouterEmbeddingProvider(
            configuration: OpenRouterConfiguration(apiKey: "sk-or-v1-test"),
            model: "openai/text-embedding-3-small",
            dimension: Self.dimension,
            session: StubURLProtocol.makeSession()
        )
    }

    private func stub(_ body: String, status: Int = 200) {
        StubURLProtocol.setStubs([
            .init(
                statusCode: status,
                headers: ["Content-Type": "application/json"],
                body: Data(body.utf8)
            )
        ])
    }

    private static let goodBody = """
    {"object":"list","model":"openai/text-embedding-3-small",
    "data":[{"object":"embedding","index":0,"embedding":[0.1,0.2,0.3,0.4]}],
    "usage":{"prompt_tokens":4,"total_tokens":4}}
    """

    @Test("a vector comes back as an Embedding for retrieval")
    func embedsForRetrieval() async throws {
        stub(Self.goodBody)
        let embedding: Embedding = try await provider().embed("hello")
        #expect(embedding.vector == [0.1, 0.2, 0.3, 0.4])
        #expect(embedding.dimension == Self.dimension)
    }

    @Test("the same call serves the router, because the two protocols are the same two members")
    func embedsForRouting() async throws {
        stub(Self.goodBody)
        let vector: RouteVector = try await provider().embed("hello")
        #expect(vector.values == [0.1, 0.2, 0.3, 0.4])
    }

    @Test("the request is a POST to /embeddings carrying the scalar input")
    func requestShape() async throws {
        stub(Self.goodBody)
        let _: Embedding = try await provider().embed("hello")

        let body = try #require(StubURLProtocol.allBodies.first)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "openai/text-embedding-3-small")
        // A scalar, not a one-element array: both are accepted, and this is the shape every
        // provider behind OpenRouter documents.
        #expect(json["input"] as? String == "hello")
    }

    @Test("a width other than the one configured is fatal, not something to average over")
    func dimensionMismatchThrows() async throws {
        stub(#"{"data":[{"index":0,"embedding":[0.1,0.2]}]}"#)
        await #expect(throws: EmbeddingError.dimensionMismatch(expected: 4, received: 2)) {
            let _: Embedding = try await provider().embed("hello")
        }
    }

    @Test("an error status is reported with its status rather than as a decode failure")
    func httpErrorIsReported() async throws {
        stub(#"{"error":{"message":"insufficient credit"}}"#, status: 402)
        await #expect(throws: EmbeddingError.self) {
            let _: Embedding = try await provider().embed("hello")
        }
    }

    @Test("a response with no embeddings is malformed, not an empty vector")
    func emptyDataThrows() async throws {
        stub(#"{"data":[]}"#)
        await #expect(throws: EmbeddingError.malformed("the response carried no embeddings")) {
            let _: Embedding = try await provider().embed("hello")
        }
    }

    @Test("a body that is not the documented shape fails loudly")
    func malformedBodyThrows() async throws {
        stub("not json at all")
        await #expect(throws: EmbeddingError.self) {
            let _: Embedding = try await provider().embed("hello")
        }
    }

    @Test("an unreachable endpoint throws rather than quietly returning a zero vector")
    func transportFailureThrows() async throws {
        // The tempting alternative — return `Embedding(vector: .init(repeating: 0, count: n))` —
        // scores 0 against everything, so retrieval would appear to work and find nothing.
        StubURLProtocol.fail(with: URLError(.notConnectedToInternet))
        await #expect(throws: EmbeddingError.self) {
            let _: Embedding = try await provider().embed("hello")
        }
    }

    @Test("no key means no call at all")
    func missingKeyThrows() async throws {
        let unkeyed = OpenRouterEmbeddingProvider(
            configuration: OpenRouterConfiguration(apiKey: ""),
            session: StubURLProtocol.makeSession()
        )
        #expect(OpenRouterEmbeddingProvider.isUsable(OpenRouterConfiguration(apiKey: "")) == false)
        await #expect(throws: EmbeddingError.notConfigured) {
            let _: Embedding = try await unkeyed.embed("hello")
        }
    }

    @Test("every error says something a person could act on")
    func errorsAreLegible() {
        let errors: [EmbeddingError] = [
            .notConfigured,
            .transport("offline"),
            .http(status: 402, message: "no credit"),
            .malformed("bad json"),
            .dimensionMismatch(expected: 1_536, received: 256)
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }

    // MARK: - The composition decision

    @Test("a key selects the hosted embedder; its absence keeps the bag-of-words one")
    func compositionPicksOneEmbedderAndKeepsIt() {
        let keyed = Composition.makeEmbedder(
            configuration: OpenRouterConfiguration(apiKey: "sk-or-v1-test")
        )
        #expect(keyed is OpenRouterEmbeddingProvider)
        #expect(keyed.dimension == OpenRouterEmbeddingProvider.defaultDimension)

        // Unkeyed and absent both fall back, and to the *same* width — the whole point of deciding
        // once is that a single index never sees two.
        let unkeyed = Composition.makeEmbedder(
            configuration: OpenRouterConfiguration(apiKey: "")
        )
        let absent = Composition.makeEmbedder(configuration: nil)
        #expect(unkeyed is HashingEmbeddingProvider)
        #expect(absent is HashingEmbeddingProvider)
        #expect(unkeyed.dimension == absent.dimension)
        #expect(
            unkeyed.dimension != OpenRouterEmbeddingProvider.defaultDimension,
            "if the widths matched, mixing them would be harmless and this rule pointless"
        )
    }
}
