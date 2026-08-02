import Foundation
import SwiftUI

/// What the picker is currently narrowed to.
///
/// A value rather than four `@State` booleans so the combination can be unit-tested. The
/// interesting cases are combinations — "free *and* tool-capable" returns a much shorter list than
/// either alone — and a filter that only ever ran inside a `body` could not be asserted on.
struct ModelFilter: Sendable, Equatable {
    /// What counts as a large window. 128K is the round number the market settled on and the one
    /// GPT-4o publishes, so it splits the catalogue where a reader expects it to.
    static let largeContextThreshold = 128_000

    var freeOnly = false
    var toolCapableOnly = false
    var visionOnly = false
    var largeContextOnly = false
    var searchText = ""

    var isNarrowed: Bool {
        freeOnly || toolCapableOnly || visionOnly || largeContextOnly
            || !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The models this filter admits.
    ///
    /// Every path starts from `catalog.selectable`, which is the single place the `-1` sentinel is
    /// excluded. Filtering `catalog.models` instead would put a price on the five router models
    /// the moment somebody added a filter that happened not to reject them, and every figure shown
    /// against those is invented — their upstream is chosen per request.
    func apply(to catalog: ModelCatalog) -> [OpenRouterModel] {
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return catalog.selectable.filter { model in
            if freeOnly && model.price?.kind != .free { return false }
            if toolCapableOnly && !model.supportsToolCalling { return false }
            if visionOnly && !model.supportsVision { return false }
            if largeContextOnly && (model.contextLength ?? 0) < Self.largeContextThreshold {
                return false
            }
            guard !needle.isEmpty else { return true }
            return model.displayName.lowercased().contains(needle)
                || model.id.lowercased().contains(needle)
        }
    }
}

/// How one model's facts are worded.
enum ModelPresentation {
    /// Prompt and completion rates, per million tokens.
    ///
    /// Formatted from the `Decimal` the catalogue normalised, never from a `Double` round trip —
    /// the whole reason `ModelPrice` keeps `Decimal` is that a rate like `0.0000025` does not
    /// survive binary floating point intact, and a price list is the last place to spend that.
    static func priceText(for model: OpenRouterModel) -> String {
        guard let price = model.price else { return "Price unknown" }
        switch price.kind {
        case .free:
            return "Free"
        case .variable:
            // Unreachable from the picker, which only ever shows `selectable`. Kept because a
            // caller that did reach it must be told the price is unknowable, not shown a zero.
            return "Priced per request"
        case .priced:
            return "\(usd(price.promptPerMillion)) in · \(usd(price.completionPerMillion)) out / M"
        }
    }

    static func usd(_ value: Decimal) -> String {
        "$" + value.formatted(.number.precision(.fractionLength(2...4)))
    }

    /// The context window, rounded only when rounding loses nothing.
    ///
    /// `128000` reads as `128K` and `2000000` as `2M`, but `262144` stays `262,144`: calling it
    /// "262K" would be a number nobody could check against the catalogue, and this screen exists to
    /// report facts.
    static func contextText(for model: OpenRouterModel) -> String {
        guard let tokens = model.contextLength, tokens > 0 else { return "Context unknown" }
        if tokens % 1_000_000 == 0 { return "\(tokens / 1_000_000)M context" }
        if tokens % 1_000 == 0 { return "\(tokens / 1_000)K context" }
        return "\(tokens.formatted(.number)) context"
    }

    /// The badges, derived from the same properties the router and the decoder read. Nothing here
    /// re-implements a capability check — a badge that disagreed with the code that acts on it
    /// would be worse than no badge.
    static func badges(for model: OpenRouterModel) -> [Badge] {
        var badges: [Badge] = []
        if model.supportsToolCalling {
            badges.append(Badge(label: "Tools", icon: "wrench.and.screwdriver"))
        }
        if model.supportsStructuredOutputs {
            badges.append(Badge(label: "Structured", icon: "curlybraces"))
        }
        if model.supportsVision {
            badges.append(Badge(label: "Vision", icon: "eye"))
        }
        return badges
    }

    struct Badge: Identifiable, Equatable {
        let label: String
        let icon: String
        var id: String { label }
    }
}

/// Loads the catalogue and holds what the picker is showing.
@MainActor
@Observable
final class ModelPickerViewModel {
    enum Phase: Equatable {
        case loading
        case loaded
        /// The catalogue could not be fetched. The message is shown; an empty list is not, because
        /// "no models match" and "we could not ask" are different things to a reader.
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var catalog = ModelCatalog(models: [])
    var filter = ModelFilter()

    private let source: any ModelCatalogProviding

    init(source: any ModelCatalogProviding) {
        self.source = source
    }

    var models: [OpenRouterModel] { filter.apply(to: catalog) }

    /// How many entries the catalogue carried that cannot be priced.
    ///
    /// Surfaced rather than silently dropped: a user who knows `openrouter/auto` exists and cannot
    /// find it deserves the reason, and the reason is interesting — it is the one thing in the
    /// catalogue whose cost is not knowable before the call.
    var hiddenUnpricedCount: Int { catalog.models.count - catalog.selectable.count }

    func load() async {
        phase = .loading
        do {
            catalog = try await source.fetchCatalog()
            phase = .loaded
        } catch {
            phase = .failed("\(error)")
        }
    }
}
