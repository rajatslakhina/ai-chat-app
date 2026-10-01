import ModelCascadeKit

/// `ModelCascadeKit` asks a cheap model first and pays for a stronger one only when the cheap
/// answer fails a deferral rule. This app cannot give it an honest job yet:
///
/// 1. **Only one model reaches the wire.** `PreModelPipeline.chooseModel` sets `turn.modelID`, but
///    `OpenRouterProvider.makeURLRequest` always sends `OpenRouterConfiguration.model`, so there is
///    no cheaper tier to try first and no stronger tier to escalate to. Fixing that changes which
///    paid model every turn calls, so it is tracked in the README rather than done here.
/// 2. **Replies stream live.** `ProviderEffectExecutor.streamOnce` hands each delta to the UI as it
///    arrives. A cascade must judge a *finished* answer before showing it, so a deferred cheap
///    answer would already be on screen when the stronger one replaced it.
/// 3. **There is no confidence signal to defer on.** OpenRouter's stream carries no log-probs here,
///    and the post-model judges run after the reply is shown. A `ConfidenceFloor` over a missing
///    signal would escalate every turn, which is the frontier model with extra steps.
///
/// The stage is recorded on every path that reaches the provider, so Diagnostics shows an explained
/// skip rather than an unreached package.
enum ModelCascadeSkip {
    static let reason = "one model on the wire and live-streamed replies with no confidence signal; "
        + "no tier to defer from or to"

    static var outcome: StageOutcome { .skipped(reason: reason) }

    /// What the cascade *would* do with a missing confidence signal, pinned by a test so the
    /// third reason above stays true of the package the app links: it escalates.
    static func escalatesWithoutConfidence() -> Bool {
        let tier = CascadeTier(id: "openrouter", modelID: "configured", estimatedCost: 0)
        let unrated = TierAnswer(text: "reply", confidence: nil, cost: 0)
        return ConfidenceFloor(0.8).evaluate(unrated, at: tier) != .accept
    }
}
