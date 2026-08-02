import Foundation
import ProviderGatewayKit
import Testing
@testable import AIChatApp

private let fixture = StaticModelCatalog.fixture

@Suite("Model filter")
struct ModelFilterTests {
    /// The assertion the whole screen turns on. Every filter combination — including none at all —
    /// must exclude the `-1` sentinel, because every cost shown against a router model would be
    /// invented: it picks its upstream after the request is sent.
    @Test("no combination of filters can surface a variable-priced router")
    func sentinelIsNeverSelectable() {
        for freeOnly in [false, true] {
            for tools in [false, true] {
                for vision in [false, true] {
                    for large in [false, true] {
                        let filter = ModelFilter(
                            freeOnly: freeOnly,
                            toolCapableOnly: tools,
                            visionOnly: vision,
                            largeContextOnly: large
                        )
                        let ids = filter.apply(to: fixture).map(\.id)
                        #expect(!ids.contains("openrouter/auto"))
                    }
                }
            }
        }
    }

    @Test("searching by name or slug still cannot reach the router")
    func searchCannotReachTheSentinel() {
        var filter = ModelFilter()
        filter.searchText = "auto"
        #expect(filter.apply(to: fixture).isEmpty)
        filter.searchText = "openrouter"
        #expect(filter.apply(to: fixture).isEmpty)
    }

    @Test("an unfiltered picker shows every priced model, cheapest first")
    func unfiltered() {
        #expect(
            ModelFilter().apply(to: fixture).map(\.id) == [
                "inclusionai/ling-3.0-flash:free",
                "google/gemini-3.1-flash-lite-image",
                "openai/gpt-4o"
            ]
        )
    }

    @Test("free only keeps the genuinely zero-priced model")
    func freeOnly() {
        var filter = ModelFilter()
        filter.freeOnly = true
        #expect(filter.apply(to: fixture).map(\.id) == ["inclusionai/ling-3.0-flash:free"])
    }

    @Test("tool capability needs both tools and tool_choice, as the model type computes it")
    func toolCapable() {
        var filter = ModelFilter()
        filter.toolCapableOnly = true
        let ids = filter.apply(to: fixture).map(\.id)
        #expect(ids == ["inclusionai/ling-3.0-flash:free", "openai/gpt-4o"])
        #expect(!ids.contains("google/gemini-3.1-flash-lite-image"))
    }

    @Test("vision reads off input_modalities")
    func vision() {
        var filter = ModelFilter()
        filter.visionOnly = true
        #expect(
            filter.apply(to: fixture).map(\.id)
                == ["google/gemini-3.1-flash-lite-image", "openai/gpt-4o"]
        )
    }

    @Test("large context is inclusive of the threshold and excludes an unknown window")
    func largeContext() throws {
        var filter = ModelFilter()
        filter.largeContextOnly = true
        let ids = filter.apply(to: fixture).map(\.id)
        #expect(ids == ["inclusionai/ling-3.0-flash:free", "openai/gpt-4o"])

        let json = #"{"id":"x/y","pricing":{"prompt":"0","completion":"0"}}"#
        let unknown = try JSONDecoder().decode(OpenRouterModel.self, from: Data(json.utf8))
        #expect(filter.apply(to: ModelCatalog(models: [unknown])).isEmpty)
    }

    @Test("combined filters intersect rather than accumulate")
    func combined() {
        var filter = ModelFilter()
        filter.freeOnly = true
        filter.visionOnly = true
        #expect(filter.apply(to: fixture).isEmpty, "the free model is text-only")

        filter.visionOnly = false
        filter.toolCapableOnly = true
        #expect(filter.apply(to: fixture).map(\.id) == ["inclusionai/ling-3.0-flash:free"])
    }

    @Test("search matches name and slug, case-insensitively, and ignores padding")
    func search() {
        var filter = ModelFilter()
        filter.searchText = "  GPT-4O "
        #expect(filter.apply(to: fixture).map(\.id) == ["openai/gpt-4o"])
        filter.searchText = "ling"
        #expect(filter.apply(to: fixture).map(\.id) == ["inclusionai/ling-3.0-flash:free"])
    }

    @Test("isNarrowed reports whether anything is actually filtering")
    func narrowed() {
        #expect(!ModelFilter().isNarrowed)
        var filter = ModelFilter()
        filter.searchText = "   "
        #expect(!filter.isNarrowed, "whitespace is not a search")
        filter.searchText = "x"
        #expect(filter.isNarrowed)
        #expect(ModelFilter(visionOnly: true).isNarrowed)
    }
}

@Suite("Model presentation")
struct ModelPresentationTests {
    private func model(_ id: String) throws -> OpenRouterModel {
        try #require(fixture.model(id: id))
    }

    @Test("a priced model shows both rates per million")
    func pricedText() throws {
        let text = ModelPresentation.priceText(for: try model("openai/gpt-4o"))
        #expect(text.contains("2.50"))
        #expect(text.contains("10.00"))
        #expect(text.hasSuffix("/ M"))
    }

    @Test("free reads as free, not as $0.00")
    func freeText() throws {
        #expect(
            ModelPresentation.priceText(for: try model("inclusionai/ling-3.0-flash:free")) == "Free"
        )
    }

    /// Not reachable from the picker, which only renders `selectable` — but if it ever were, the
    /// answer must be "we cannot know", never a number.
    @Test("a router's price is described rather than invented")
    func variableText() throws {
        #expect(
            ModelPresentation.priceText(for: try model("openrouter/auto")) == "Priced per request"
        )
    }

    @Test("an unpriceable model says so")
    func unknownPrice() throws {
        let json = #"{"id":"x/y","pricing":{"prompt":"0.001"}}"#
        let partial = try JSONDecoder().decode(OpenRouterModel.self, from: Data(json.utf8))
        #expect(ModelPresentation.priceText(for: partial) == "Price unknown")
    }

    /// Rounding only where rounding is lossless: `262144` is not "262K", and claiming it is puts a
    /// number on screen nobody can check against the catalogue.
    @Test("context is abbreviated only when the abbreviation is exact")
    func contextText() throws {
        #expect(ModelPresentation.contextText(for: try model("openai/gpt-4o")) == "128K context")
        #expect(
            ModelPresentation.contextText(for: try model("openrouter/auto")) == "2M context"
        )
        // Asserted on the digits rather than the rendered string: the grouping separator is the
        // reader's, not ours — an en_IN device writes this window as `2,62,144`.
        let awkward = ModelPresentation.contextText(for: try model("inclusionai/ling-3.0-flash:free"))
        #expect(awkward.hasSuffix(" context"))
        #expect(awkward.filter(\.isNumber) == "262144")
        #expect(!awkward.contains("262K"), "262,144 is not 262K, and saying so would be a guess")
    }

    @Test("a model with no declared window says unknown rather than zero")
    func unknownContext() throws {
        let json = #"{"id":"x/y","pricing":{"prompt":"0","completion":"0"}}"#
        let model = try JSONDecoder().decode(OpenRouterModel.self, from: Data(json.utf8))
        #expect(ModelPresentation.contextText(for: model) == "Context unknown")
    }

    @Test("badges come from the same properties the pipeline acts on")
    func badges() throws {
        let full = ModelPresentation.badges(for: try model("openai/gpt-4o")).map(\.label)
        #expect(full == ["Tools", "Structured", "Vision"])

        let free = ModelPresentation.badges(for: try model("inclusionai/ling-3.0-flash:free"))
        #expect(free.map(\.label) == ["Tools"], "no structured_outputs means no badge")

        let noTools = ModelPresentation.badges(
            for: try model("google/gemini-3.1-flash-lite-image")
        )
        #expect(noTools.map(\.label) == ["Vision"])
    }
}

/// A catalogue source that fails, so the picker's error path is a real one.
private struct FailingCatalog: ModelCatalogProviding {
    func fetchCatalog() async throws -> ModelCatalog {
        throw ProviderError.connectionFailed("no route to host")
    }

    func fetchKeyStatus() async throws -> OpenRouterKeyStatus {
        throw ProviderError.connectionFailed("no route to host")
    }
}

@MainActor
@Suite("Model picker view model")
struct ModelPickerViewModelTests {
    @Test("a successful load exposes the catalogue and counts what it had to hide")
    func loads() async {
        let model = ModelPickerViewModel(source: StaticModelCatalog())
        await model.load()

        #expect(model.phase == .loaded)
        #expect(model.models.count == 3)
        #expect(model.hiddenUnpricedCount == 1, "openrouter/auto cannot be priced")
    }

    /// An empty list would read as "OpenRouter has no models", which is false and unactionable.
    @Test("a failed load is a named failure, not an empty catalogue")
    func failure() async {
        let model = ModelPickerViewModel(source: FailingCatalog())
        await model.load()

        guard case let .failed(message) = model.phase else {
            Issue.record("expected .failed, got \(model.phase)")
            return
        }
        #expect(message.contains("no route to host"))
        #expect(model.models.isEmpty)
    }

    @Test("filtering runs against whatever was loaded")
    func filters() async {
        let model = ModelPickerViewModel(source: StaticModelCatalog())
        await model.load()
        model.filter.freeOnly = true
        #expect(model.models.map(\.id) == ["inclusionai/ling-3.0-flash:free"])
    }
}

@Suite("UI-test catalogue fixture")
struct StaticModelCatalogTests {
    /// The fixture is only worth having if it is the real shape. A UI test asserting the sentinel
    /// is excluded proves nothing against a catalogue that never contained one.
    @Test("the fixture carries a real -1 sentinel that the picker must exclude")
    func carriesTheSentinel() async throws {
        let catalog = try await StaticModelCatalog().fetchCatalog()
        let auto = try #require(catalog.model(id: "openrouter/auto"))
        #expect(auto.price?.kind == .variable)
        #expect(!catalog.selectable.contains { $0.id == "openrouter/auto" })
        #expect(catalog.models.count == 4)
        #expect(catalog.selectable.count == 3)
    }

    /// `limit: null` is the case Settings must render as unlimited rather than as nothing left.
    @Test("the fixture key has no limit, so Settings has that case to render")
    func keyStatusIsUnlimited() async throws {
        let status = try await StaticModelCatalog().fetchKeyStatus()
        #expect(status.limit == nil)
        #expect(status.remainingDescription == "Unlimited")
        #expect(!status.isExhausted)
    }
}
