import Foundation

/// Where the model picker and the Settings screen get their facts.
///
/// A protocol rather than a direct dependency on `ModelCatalogClient` for one reason: a UI test
/// that drives the picker must not reach openrouter.ai. Stubbing at `URLProtocol` works for unit
/// tests, which run in the app's process, but a XCUITest launches the app as a separate process
/// where no test code is linked. The seam has to be inside the app, which is the same reason
/// `UnavailableBiometrics` and `InMemoryKeychain` ship in `Sources/`.
protocol ModelCatalogProviding: Sendable {
    func fetchCatalog() async throws -> ModelCatalog
    func fetchKeyStatus() async throws -> OpenRouterKeyStatus
}

extension ModelCatalogClient: ModelCatalogProviding {}

/// A fixed catalog, used when the app launches under `-UITestMode`.
///
/// The four entries are copied verbatim from a live `GET /api/v1/models` — one ordinary paid
/// model, one `-1` router sentinel, one genuinely free model, and one without tool support. The
/// sentinel is the point: a UI test can assert that `openrouter/auto` never appears in a list that
/// shows prices, and that assertion is worthless against a catalog invented to make it pass.
struct StaticModelCatalog: ModelCatalogProviding {
    let catalog: ModelCatalog
    let keyStatus: OpenRouterKeyStatus

    init(catalog: ModelCatalog = StaticModelCatalog.fixture, keyStatus: OpenRouterKeyStatus = .demo) {
        self.catalog = catalog
        self.keyStatus = keyStatus
    }

    func fetchCatalog() async throws -> ModelCatalog { catalog }

    func fetchKeyStatus() async throws -> OpenRouterKeyStatus { keyStatus }

    static let fixture = ModelCatalog(models: [
        OpenRouterModel(
            id: "openai/gpt-4o",
            name: "OpenAI: GPT-4o",
            contextLength: 128_000,
            pricing: .init(prompt: "0.0000025", completion: "0.00001", inputCacheRead: "0.00000125"),
            architecture: .init(inputModalities: ["text", "image", "file"]),
            supportedParameters: ["max_tokens", "response_format", "structured_outputs",
                                  "temperature", "tool_choice", "tools", "top_p"],
            topProvider: .init(maxCompletionTokens: 16_384)
        ),
        OpenRouterModel(
            id: "openrouter/auto",
            name: "Auto Router",
            contextLength: 2_000_000,
            pricing: .init(prompt: "-1", completion: "-1", inputCacheRead: nil),
            architecture: .init(inputModalities: ["text", "image"]),
            supportedParameters: ["tools", "tool_choice"],
            topProvider: nil
        ),
        OpenRouterModel(
            id: "inclusionai/ling-3.0-flash:free",
            name: "Ling 3.0 Flash (free)",
            contextLength: 262_144,
            pricing: .init(prompt: "0", completion: "0", inputCacheRead: nil),
            architecture: .init(inputModalities: ["text"]),
            supportedParameters: ["tools", "tool_choice", "temperature"],
            topProvider: nil
        ),
        OpenRouterModel(
            id: "google/gemini-3.1-flash-lite-image",
            name: "Gemini 3.1 Flash Lite Image",
            contextLength: 65_536,
            pricing: .init(prompt: "0.00000025", completion: "0.000001", inputCacheRead: nil),
            architecture: .init(inputModalities: ["text", "image"]),
            supportedParameters: ["max_tokens", "temperature"],
            topProvider: nil
        )
    ])
}

extension OpenRouterKeyStatus {
    /// A key with no ceiling. `limit: nil` is the case Settings has to render as *unlimited* rather
    /// than as zero, so the fixture pins it — a UI test asserting "Unlimited" against a status that
    /// carried a real limit would pass for the wrong reason.
    static let demo = OpenRouterKeyStatus(
        label: "sk-or-v1-ui…test",
        usage: 0.0184,
        limit: nil,
        limitRemaining: nil,
        isFreeTier: true
    )
}
