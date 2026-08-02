import Foundation
import ProviderGatewayKit

/// What one completed OpenRouter call actually consumed.
///
/// This type exists because of a real gap in the seam, and it is worth naming rather than
/// working around silently: `ProviderGatewayKit.LLMResponse` carries `text`, `finishReason` and
/// `providerID` — and no token counts. That is a reasonable choice for a routing library, which
/// has no business modelling every vendor's billing envelope. But `TokenMeterKit` needs prompt
/// and completion tokens, and they only exist inside the provider.
///
/// So usage travels out of band: the provider reports here as each call completes, and the app
/// reads it. The alternative — smuggling counts into `LLMResponse.text` or re-estimating from
/// character counts after the fact — would put a fabricated number in front of a cost figure,
/// which is worse than no number at all.
struct OpenRouterUsage: Sendable, Equatable {
    let requestID: String?
    let model: String
    let promptTokens: Int
    let completionTokens: Int
    let cachedPromptTokens: Int

    /// What OpenRouter says it charged, in USD, when `usage.include` was requested.
    ///
    /// Kept separate from any locally-computed figure. When this is present it is the truth and
    /// a local price table is at best a corroboration; when it is absent, the app prices the
    /// call itself and labels it as an estimate.
    let reportedCostUSD: Double?

    var totalTokens: Int { promptTokens + completionTokens }
}

/// Receives usage as calls complete.
///
/// A protocol so the provider can be tested without standing up the app's real metering stack,
/// and so a UI-test launch can record into nothing at all.
protocol UsageObserving: Sendable {
    func record(_ usage: OpenRouterUsage) async
}

/// Collects usage in memory, newest last.
///
/// An actor because the provider is `Sendable` and may have several calls in flight — the
/// router's fallback chain and any batch fan-out both produce concurrent completions.
actor UsageRecorder: UsageObserving {
    private(set) var records: [OpenRouterUsage] = []

    func record(_ usage: OpenRouterUsage) {
        records.append(usage)
    }

    var totalPromptTokens: Int { records.reduce(0) { $0 + $1.promptTokens } }
    var totalCompletionTokens: Int { records.reduce(0) { $0 + $1.completionTokens } }

    /// Sum of what OpenRouter reported charging. `nil` when no call reported a cost, which is
    /// different from zero and is shown differently.
    var reportedCostUSD: Double? {
        let reported = records.compactMap(\.reportedCostUSD)
        return reported.isEmpty ? nil : reported.reduce(0, +)
    }

    var mostRecent: OpenRouterUsage? { records.last }

    func reset() {
        records.removeAll()
    }
}

/// Discards usage. Used by UI tests, where metering is not under test and a growing array
/// across a long launch is just noise.
struct NullUsageObserver: UsageObserving {
    func record(_ usage: OpenRouterUsage) async {}
}
