import Foundation
import TokenMeterKit

/// How a model is priced, kept as a case rather than a number.
///
/// OpenRouter overloads the pricing strings with two sentinels, and both mean something a bare
/// `Decimal` cannot express:
///
/// - `"0"` — genuinely free (17 of 365 models at the time of writing).
/// - `"-1"` — the price is not knowable up front, because the model is a *router* that picks an
///   upstream per request. Five models do this: `openrouter/auto`, `auto-beta`, `fusion`,
///   `pareto-code`, `bodybuilder`. Treating `-1` as a number produces negative costs, and
///   negative costs added to a running total silently reduce it.
enum ModelPricingKind: Sendable, Equatable {
    case free
    case priced
    /// Price resolved per request by an upstream router; no forecast is possible.
    case variable
}

/// A model's price, normalized to what `TokenMeterKit.ModelPricing` expects.
///
/// OpenRouter quotes **per token** as a decimal string (`"0.0000025"`); `ModelPricing` takes
/// **per million** as a `Decimal`. The conversion goes through `Decimal(string:)` and stays in
/// `Decimal` throughout — routing it via `Double` would introduce binary-float error into a money
/// value at the very first step, which is the mistake the whole ecosystem's integer-microcent
/// discipline exists to avoid.
struct ModelPrice: Sendable, Equatable {
    let promptPerMillion: Decimal
    let completionPerMillion: Decimal
    let cachedReadPerMillion: Decimal?
    let kind: ModelPricingKind

    private static let million = Decimal(1_000_000)

    /// Parses one pricing string. Returns nil when the value is absent or unparseable — which is
    /// different from zero and must not be collapsed into it.
    static func perMillion(_ raw: String?) -> Decimal? {
        guard let raw, !raw.isEmpty, let value = Decimal(string: raw) else { return nil }
        return value * million
    }

    init?(_ pricing: OpenRouterModel.Pricing) {
        // The sentinel check happens before any arithmetic, deliberately.
        if pricing.prompt == "-1" || pricing.completion == "-1" {
            self.kind = .variable
            self.promptPerMillion = 0
            self.completionPerMillion = 0
            self.cachedReadPerMillion = nil
            return
        }
        guard let prompt = Self.perMillion(pricing.prompt),
              let completion = Self.perMillion(pricing.completion) else { return nil }
        self.promptPerMillion = prompt
        self.completionPerMillion = completion
        self.cachedReadPerMillion = Self.perMillion(pricing.inputCacheRead)
        self.kind = (prompt == 0 && completion == 0) ? .free : .priced
    }

    /// The value handed to `TokenMeterKit`. `nil` for `.variable`, because registering a zero
    /// there would make every routed call report as free rather than as unknown.
    var meterPricing: ModelPricing? {
        guard kind != .variable else { return nil }
        return ModelPricing(
            inputPerMillion: promptPerMillion,
            outputPerMillion: completionPerMillion
        )
    }
}

/// One entry from `GET /api/v1/models`.
struct OpenRouterModel: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String?
    let contextLength: Int?
    let pricing: Pricing
    let architecture: Architecture?
    let supportedParameters: [String]?
    let topProvider: TopProvider?

    enum CodingKeys: String, CodingKey {
        case id, name, pricing, architecture
        case contextLength = "context_length"
        case supportedParameters = "supported_parameters"
        case topProvider = "top_provider"
    }

    struct Pricing: Decodable, Equatable, Sendable {
        let prompt: String?
        let completion: String?
        let inputCacheRead: String?

        enum CodingKeys: String, CodingKey {
            case prompt, completion
            case inputCacheRead = "input_cache_read"
        }
    }

    struct Architecture: Decodable, Equatable, Sendable {
        let inputModalities: [String]?

        enum CodingKeys: String, CodingKey {
            case inputModalities = "input_modalities"
        }
    }

    struct TopProvider: Decodable, Equatable, Sendable {
        let maxCompletionTokens: Int?

        enum CodingKeys: String, CodingKey {
            case maxCompletionTokens = "max_completion_tokens"
        }
    }

    struct Response: Decodable, Equatable, Sendable {
        let data: [OpenRouterModel]
    }
}

extension OpenRouterModel {
    var displayName: String { name ?? id }

    var price: ModelPrice? { ModelPrice(pricing) }

    /// Tool calling requires **both** parameters.
    ///
    /// A model advertising `tools` but not `tool_choice` cannot be driven reliably through a
    /// tool-calling loop, and the router would keep selecting it and keep failing. Checking only
    /// `tools` over-reports capability.
    var supportsToolCalling: Bool {
        let parameters = Set(supportedParameters ?? [])
        return parameters.contains("tools") && parameters.contains("tool_choice")
    }

    /// Schema-constrained output, which is what `StructuredOutputKit` needs.
    ///
    /// The flag is `structured_outputs`, not `response_format`: the latter is advertised far more
    /// widely and only promises "some JSON", not "JSON matching this schema".
    var supportsStructuredOutputs: Bool {
        (supportedParameters ?? []).contains("structured_outputs")
    }

    var supportsVision: Bool {
        (architecture?.inputModalities ?? []).contains("image")
    }

    /// The price a picker may put on screen, or nil when there is none it could honestly show.
    ///
    /// `.variable` models resolve their price per request from whatever upstream they route to, so
    /// every cost figure displayed against them would be invented.
    var displayablePrice: ModelPrice? {
        guard let price, price.kind != .variable else { return nil }
        return price
    }

    /// Whether this model belongs in a picker that displays costs.
    var isSelectableWithKnownCost: Bool { displayablePrice != nil }
}

/// The models available, with prices already normalized.
struct ModelCatalog: Sendable, Equatable {
    let models: [OpenRouterModel]

    init(models: [OpenRouterModel]) {
        self.models = models
    }

    /// Models safe to show in a picker with a price attached, cheapest first.
    ///
    /// The price is carried through the sort rather than re-read on each side of the comparison:
    /// `displayablePrice` has already established that every survivor has one, so re-reading the
    /// optional needed a `?? 0` fallback that no catalogue could reach.
    var selectable: [OpenRouterModel] {
        models
            .compactMap { model in model.displayablePrice.map { (model: model, price: $0) } }
            .sorted { lhs, rhs in
                if lhs.price.promptPerMillion == rhs.price.promptPerMillion {
                    return lhs.model.id < rhs.model.id
                }
                return lhs.price.promptPerMillion < rhs.price.promptPerMillion
            }
            .map(\.model)
    }

    var free: [OpenRouterModel] { selectable.filter { $0.price?.kind == .free } }

    var toolCapable: [OpenRouterModel] { selectable.filter(\.supportsToolCalling) }

    func model(id: String) -> OpenRouterModel? { models.first { $0.id == id } }

    /// Registers every known price with a `TokenMeterKit` registry.
    ///
    /// This is the step that stops the app reporting `$0.00` for everything. `TokenMeter` prices a
    /// recorded usage by looking the model id up in its registry; a model that was never
    /// registered contributes nothing to the total, silently. Returns how many were registered so
    /// a caller can assert on it rather than hope.
    @discardableResult
    func installPricing(into registry: PricingRegistry) async -> Int {
        var installed = 0
        for model in models {
            guard let pricing = model.price?.meterPricing else { continue }
            await registry.register(pricing, for: model.id)
            installed += 1
        }
        return installed
    }
}
