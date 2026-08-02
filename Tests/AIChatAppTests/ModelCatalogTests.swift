import Foundation
import ProviderGatewayKit
import Testing
import TokenMeterKit
@testable import AIChatApp

/// Four models taken verbatim from a live `GET /api/v1/models`, one per case that matters:
/// a normal paid model, the `-1` router sentinel, a genuinely free model, and one without tools.
private let liveModelsJSON = """
{
 "data": [
  {
   "id": "openai/gpt-4o",
   "name": "OpenAI: GPT-4o",
   "context_length": 128000,
   "architecture": { "input_modalities": ["text", "image", "file"] },
   "pricing": {
    "prompt": "0.0000025",
    "completion": "0.00001",
    "input_cache_read": "0.00000125"
   },
   "top_provider": { "max_completion_tokens": 16384 },
   "supported_parameters": ["max_tokens", "response_format", "structured_outputs",
                            "temperature", "tool_choice", "tools", "top_p"]
  },
  {
   "id": "openrouter/auto",
   "name": "Auto Router",
   "context_length": 2000000,
   "architecture": { "input_modalities": ["text", "image"] },
   "pricing": { "prompt": "-1", "completion": "-1" },
   "supported_parameters": ["tools", "tool_choice"]
  },
  {
   "id": "inclusionai/ling-3.0-flash:free",
   "name": "Ling 3.0 Flash (free)",
   "context_length": 262144,
   "architecture": { "input_modalities": ["text"] },
   "pricing": { "prompt": "0", "completion": "0" },
   "supported_parameters": ["tools", "tool_choice", "temperature"]
  },
  {
   "id": "google/gemini-3.1-flash-lite-image",
   "name": "Gemini 3.1 Flash Lite Image",
   "context_length": 65536,
   "architecture": { "input_modalities": ["text", "image"] },
   "pricing": { "prompt": "0.00000025", "completion": "0.000001" },
   "supported_parameters": ["max_tokens", "temperature"]
  }
 ]
}
"""

private func decodeCatalog() throws -> ModelCatalog {
    let response = try JSONDecoder().decode(
        OpenRouterModel.Response.self,
        from: Data(liveModelsJSON.utf8)
    )
    return ModelCatalog(models: response.data)
}

@Suite("Model pricing")
struct ModelPricingTests {
    @Test("per-token strings convert to per-million without going through Double")
    func perMillionConversion() throws {
        let catalog = try decodeCatalog()
        let model = try #require(catalog.model(id: "openai/gpt-4o"))
        let price = try #require(model.price)

        #expect(price.kind == .priced)
        // $0.0000025/token = $2.50/M. Exact in Decimal; via Double it would not be.
        #expect(price.promptPerMillion == Decimal(string: "2.5"))
        #expect(price.completionPerMillion == Decimal(string: "10"))
        #expect(price.cachedReadPerMillion == Decimal(string: "1.25"))
    }

    @Test("the -1 sentinel is a kind, never a negative price")
    func variablePricingSentinel() throws {
        let catalog = try decodeCatalog()
        let auto = try #require(catalog.model(id: "openrouter/auto"))
        let price = try #require(auto.price)

        #expect(price.kind == .variable)
        #expect(price.promptPerMillion >= 0, "a negative rate would reduce a running total")
        #expect(
            price.meterPricing == nil,
            "registering zero would report every routed call as free rather than as unknown"
        )
        #expect(!auto.isSelectableWithKnownCost)
    }

    @Test("zero pricing is free, which is not the same as unknown")
    func freePricing() throws {
        let catalog = try decodeCatalog()
        let free = try #require(catalog.model(id: "inclusionai/ling-3.0-flash:free"))
        let price = try #require(free.price)

        #expect(price.kind == .free)
        #expect(price.meterPricing != nil, "a free model is still priced, at zero")
        #expect(free.isSelectableWithKnownCost)
    }

    @Test("an absent or unparseable rate is nil rather than zero")
    func unparseableRate() {
        #expect(ModelPrice.perMillion(nil) == nil)
        #expect(ModelPrice.perMillion("") == nil)
        #expect(ModelPrice.perMillion("not-a-number") == nil)
        #expect(ModelPrice.perMillion("0") == 0)
    }

    @Test("a model missing its completion rate produces no price at all")
    func partialPricing() throws {
        let json = #"{"id":"x","pricing":{"prompt":"0.001"}}"#
        let model = try JSONDecoder().decode(OpenRouterModel.self, from: Data(json.utf8))
        #expect(model.price == nil)
        #expect(!model.isSelectableWithKnownCost)
    }
}

@Suite("Model capabilities")
struct ModelCapabilityTests {
    @Test("tool calling requires both tools and tool_choice")
    func toolCallingNeedsBoth() throws {
        let catalog = try decodeCatalog()
        #expect(try #require(catalog.model(id: "openai/gpt-4o")).supportsToolCalling)
        let noTools = try #require(catalog.model(id: "google/gemini-3.1-flash-lite-image"))
        #expect(!noTools.supportsToolCalling)

        let onlyTools = #"{"id":"p","pricing":{"prompt":"0","completion":"0"},"supported_parameters":["tools"]}"#
        let partial = try JSONDecoder().decode(
            OpenRouterModel.self,
            from: Data(onlyTools.utf8)
        )
        #expect(
            !partial.supportsToolCalling,
            "advertising tools without tool_choice cannot be driven through a tool loop"
        )
    }

    @Test("structured output keys off structured_outputs, not response_format")
    func structuredOutputs() throws {
        let catalog = try decodeCatalog()
        #expect(try #require(catalog.model(id: "openai/gpt-4o")).supportsStructuredOutputs)
        let free = try #require(catalog.model(id: "inclusionai/ling-3.0-flash:free"))
        #expect(!free.supportsStructuredOutputs)
    }

    @Test("vision keys off input_modalities containing image")
    func vision() throws {
        let catalog = try decodeCatalog()
        #expect(try #require(catalog.model(id: "openai/gpt-4o")).supportsVision)
        let textOnly = try #require(catalog.model(id: "inclusionai/ling-3.0-flash:free"))
        #expect(!textOnly.supportsVision)
    }

    @Test("display name falls back to the id when the name is absent")
    func displayNameFallback() throws {
        let json = #"{"id":"vendor/x","pricing":{"prompt":"0","completion":"0"}}"#
        let model = try JSONDecoder().decode(OpenRouterModel.self, from: Data(json.utf8))
        #expect(model.displayName == "vendor/x")
    }
}

@Suite("Model catalog")
struct ModelCatalogSuite {
    @Test("selectable excludes variable-priced routers and sorts cheapest first")
    func selectableOrdering() throws {
        let catalog = try decodeCatalog()
        let ids = catalog.selectable.map(\.id)

        #expect(
            !ids.contains("openrouter/auto"),
            "a router with no knowable price cannot be priced"
        )
        #expect(
            ids == [
                "inclusionai/ling-3.0-flash:free",
                "google/gemini-3.1-flash-lite-image",
                "openai/gpt-4o"
            ]
        )
    }

    @Test("free and tool-capable filters read off the normalized price and parameters")
    func filters() throws {
        let catalog = try decodeCatalog()
        #expect(catalog.free.map(\.id) == ["inclusionai/ling-3.0-flash:free"])
        #expect(
            catalog.toolCapable.map(\.id).sorted()
                == ["inclusionai/ling-3.0-flash:free", "openai/gpt-4o"]
        )
    }

    /// The regression that makes every cost readout zero if it breaks.
    @Test("installing pricing registers every priced model with TokenMeterKit")
    func installsPricing() async throws {
        let catalog = try decodeCatalog()
        let registry = PricingRegistry()
        let installed = await catalog.installPricing(into: registry)

        #expect(installed == 3, "3 of 4 are priced; openrouter/auto is not")
        let known = await registry.knownModels
        #expect(!known.contains("openrouter/auto"))

        let pricing = try #require(await registry.pricing(for: "openai/gpt-4o"))
        #expect(pricing.inputPerMillion == Decimal(string: "2.5"))

        // The end-to-end check: a metered call must produce a non-zero cost.
        let meter = TokenMeter(registry: registry)
        await meter.record(
            TokenMeterKit.TokenUsage(promptTokens: 1_000_000, completionTokens: 1_000_000),
            for: "openai/gpt-4o"
        )
        let cost = await meter.cost(for: "openai/gpt-4o")
        #expect(cost == Decimal(string: "12.5"), "$2.50 in + $10.00 out for a million each")
    }

    @Test("an unregistered model silently contributes nothing, which is why install matters")
    func unregisteredModelCostsZero() async throws {
        let meter = TokenMeter(registry: PricingRegistry())
        await meter.record(
            TokenMeterKit.TokenUsage(promptTokens: 1_000_000, completionTokens: 1_000_000),
            for: "openai/gpt-4o"
        )
        let cost = await meter.cost(for: "openai/gpt-4o")
        #expect(cost == 0, "this is the failure mode installPricing exists to prevent")
    }
}

@Suite("Key status")
struct KeyStatusTests {
    private func status(_ json: String) throws -> OpenRouterKeyStatus {
        try JSONDecoder().decode(OpenRouterKeyStatus.Envelope.self, from: Data(json.utf8)).data
    }

    @Test("a null limit means unlimited, not exhausted")
    func nullLimitIsUnlimited() throws {
        let json = #"{"data":{"label":"sk-or-v1-c4d...906","usage":0,"limit":null,"is_free_tier":true}}"#
        let value = try status(json)
        #expect(value.limit == nil)
        #expect(!value.isExhausted, "a funded account must not read as out of credit")
        #expect(value.remainingDescription == "Unlimited")
    }

    @Test("a real limit with nothing left reads as exhausted")
    func exhaustedLimit() throws {
        let value = try status(#"{"data":{"usage":5,"limit":5,"limit_remaining":0}}"#)
        #expect(value.isExhausted)
        #expect(value.remainingDescription == "$0.0000")
    }

    @Test("a limit with credit left formats the remainder")
    func remainingCredit() throws {
        let value = try status(#"{"data":{"usage":1,"limit":5,"limit_remaining":4.25}}"#)
        #expect(!value.isExhausted)
        #expect(value.remainingDescription == "$4.2500")
    }

    @Test("a limit present but remainder absent is unknown rather than assumed")
    func unknownRemainder() throws {
        let value = try status(#"{"data":{"usage":1,"limit":5}}"#)
        #expect(value.remainingDescription == "Unknown")
        #expect(!value.isExhausted)
    }
}

@Suite("Catalog client transport")
struct ModelCatalogClientTests {
    private func client() -> ModelCatalogClient {
        ModelCatalogClient(
            configuration: OpenRouterConfiguration(apiKey: "sk-or-v1-test"),
            session: StubURLProtocol.makeSession()
        )
    }

    @Test("fetches and decodes the catalog, sending the key")
    func fetchCatalog() async throws {
        StubURLProtocol.respond(json: liveModelsJSON)
        let catalog = try await client().fetchCatalog()

        #expect(catalog.models.count == 4)
        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-v1-test")
    }

    @Test("omits the Authorization header entirely when there is no key")
    func anonymousFetch() async throws {
        StubURLProtocol.respond(json: liveModelsJSON)
        let anonymous = ModelCatalogClient(
            configuration: OpenRouterConfiguration(apiKey: ""),
            session: StubURLProtocol.makeSession()
        )
        _ = try await anonymous.fetchCatalog()
        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("fetches key status")
    func fetchKeyStatus() async throws {
        let json = #"{"data":{"label":"k","usage":0,"limit":null,"is_free_tier":true}}"#
        StubURLProtocol.respond(json: json)
        let status = try await client().fetchKeyStatus()
        #expect(status.isFreeTier == true)
        #expect(StubURLProtocol.lastRequest?.url?.path == "/api/v1/key")
    }

    @Test("a 401 on the catalog maps onto the same error model as a chat turn")
    func unauthorizedCatalog() async throws {
        StubURLProtocol.respond(statusCode: 401, json: OpenRouterTestFixtures.unauthorizedBody)
        do {
            _ = try await client().fetchCatalog()
            Issue.record("expected a throw")
        } catch {
            guard case .capabilityMismatch = error as? ProviderError else {
                Issue.record("expected .capabilityMismatch, got \(error)")
                return
            }
        }
    }

    @Test("malformed JSON is reported as a decode failure, not as an empty catalog")
    func malformedCatalog() async throws {
        StubURLProtocol.respond(json: "{ not json")
        do {
            _ = try await client().fetchCatalog()
            Issue.record("expected a throw")
        } catch {
            guard case let .connectionFailed(message) = error as? ProviderError else {
                Issue.record("expected .connectionFailed, got \(error)")
                return
            }
            #expect(message.contains("could not decode models"))
        }
    }
}
