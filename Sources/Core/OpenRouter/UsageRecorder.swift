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

/// A streamed call that ended without its usage envelope, as far as the provider saw it.
///
/// OpenRouter sends usage in the last chunk, so a stream that ends early never delivers it: the app
/// stopped reading (a repetition cut, a cancelled turn), or the connection dropped. The call was
/// still billed, so instead of reporting nothing the provider reports what it saw, and the
/// `usageRecovery` stage turns that into a bounded charge and a billing lookup.
struct UnmeteredCall: Sendable, Equatable {
    enum Ending: Sendable, Equatable {
        /// The stream reached its end and the usage chunk never came.
        case completed
        /// The app stopped reading before the end.
        case stoppedReading
        /// The connection failed mid-stream.
        case dropped
    }

    /// From the `X-Generation-Id` header, or the first chunk's `id`.
    let generationID: String?
    let model: String
    let receivedText: String
    /// Chunks that carried answer text; each held at least one token.
    let contentChunks: Int
    let maxOutputTokens: Int
    /// The most reasoning the request allowed: the effort's share of the output limit, or 0.
    let reasoningCeiling: Int
    let ending: Ending
}

/// Receives usage as calls complete.
///
/// A protocol so the provider can be tested without standing up the app's real metering stack,
/// and so a UI-test launch can record into nothing at all.
protocol UsageObserving: Sendable {
    func record(_ usage: OpenRouterUsage) async
    /// A streamed call ended without usage. Not defaulted: an observer that silently dropped these
    /// would hide exactly the spend the report exists for.
    func recordUnmetered(_ call: UnmeteredCall) async
}

/// Collects usage in memory, newest last.
///
/// An actor because the provider is `Sendable` and may have several calls in flight — the
/// router's fallback chain and any batch fan-out both produce concurrent completions.
actor UsageRecorder: UsageObserving {
    private(set) var records: [OpenRouterUsage] = []
    private(set) var unmetered: [UnmeteredCall] = []

    func record(_ usage: OpenRouterUsage) {
        records.append(usage)
    }

    func recordUnmetered(_ call: UnmeteredCall) {
        unmetered.append(call)
    }

    /// How many calls have ended without usage, so a turn can ask which of them were its own.
    var unmeteredCount: Int { unmetered.count }

    /// The calls after `mark`, a count taken earlier from `unmeteredCount`, that ended without usage.
    func unmetered(after mark: Int) -> [UnmeteredCall] {
        Array(unmetered.dropFirst(mark))
    }

    /// The last call recorded after `mark`. Unlike `mostRecent`, never a previous turn's call: a turn
    /// that recorded nothing (a replay, or a stream that ended without usage) gets `nil`.
    func lastRecord(after mark: Int) -> OpenRouterUsage? {
        records.dropFirst(mark).last
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

    /// How many calls have been recorded, so a caller can later ask what one turn added to it.
    var recordCount: Int { records.count }

    /// The first call recorded after `mark`, a count taken earlier from `recordCount`.
    ///
    /// `mostRecent` is the wrong question for a turn that called a tool: every hop records its own
    /// usage and the last one describes the *final* prompt, tool results included. The first call
    /// after the mark is the one made with the turn's own messages, which is the one a reader of
    /// the prompt layout is asking about. `nil` means nothing was recorded — a replayed result, or
    /// an upstream that omitted its usage envelope.
    func firstRecord(after mark: Int) -> OpenRouterUsage? {
        records.dropFirst(mark).first
    }

    /// Every call recorded after `mark`, summed into one: tokens and reported cost added up, the
    /// model and request id of the last. For a turn whose cut answer was continued, both calls were
    /// billed and both belong in the month's spend. `nil` when nothing was recorded.
    func combined(after mark: Int) -> OpenRouterUsage? {
        let calls = records.dropFirst(mark)
        guard let last = calls.last else { return nil }
        let reported = calls.compactMap(\.reportedCostUSD)
        return OpenRouterUsage(
            requestID: last.requestID,
            model: last.model,
            promptTokens: calls.reduce(0) { $0 + $1.promptTokens },
            completionTokens: calls.reduce(0) { $0 + $1.completionTokens },
            cachedPromptTokens: calls.reduce(0) { $0 + $1.cachedPromptTokens },
            reportedCostUSD: reported.isEmpty ? nil : reported.reduce(0, +)
        )
    }

    func reset() {
        records.removeAll()
        unmetered.removeAll()
    }
}

/// Discards usage. Used by UI tests, where metering is not under test and a growing array
/// across a long launch is just noise.
struct NullUsageObserver: UsageObserving {
    func record(_ usage: OpenRouterUsage) async {}
    func recordUnmetered(_ call: UnmeteredCall) async {}
}
