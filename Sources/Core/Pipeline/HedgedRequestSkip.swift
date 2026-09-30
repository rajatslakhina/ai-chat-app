/// `HedgedRequestKit` sends a slow request to a backup route and keeps whichever answers first.
/// This app cannot give it an honest job yet, for three structural reasons:
///
/// 1. **There is no backup route.** `TurnExecutor` holds one `OpenRouterProvider`, and every
///    request it builds goes out with `OpenRouterConfiguration.model`. A hedge to the same model
///    on the same provider is a second copy of the same queue, not an independent path.
/// 2. **Deltas are delivered live.** `ProviderEffectExecutor.streamOnce` hands each SSE fragment
///    to the UI as it arrives. Two racing streams would both write into the visible reply;
///    hedging needs the loser's fragments held back, which is a change to the delivery path.
/// 3. **A hedge is real spend on the user's key.** It needs a budget reserved for the duplicate
///    call (see `TurnExecutor.holdBudget`), not just a policy knob.
///
/// The stage is recorded on every path that reaches the provider, so Diagnostics shows an
/// explained skip rather than an unreached package. The reason is a fact about the app, not a
/// turn, which is why it is a constant.
enum HedgedRequestSkip {
    static let reason =
        "one provider route and one model on the wire; there is no independent backup to hedge a slow call to"

    static var outcome: StageOutcome { .skipped(reason: reason) }
}
