import CensoredFeedbackKit
import ExplorationChannelKit
import Foundation

/// The one place this app is willing to answer a turn a gate wanted to refuse.
///
/// Every other gate here can only make the app more cautious. `censoredFeedback` already bends that
/// once — it withdraws enforcement when a certificate's promise does not reach this traffic — but
/// it only ever declines to enforce a promise that was never supported. This is the stronger move:
/// it answers a turn the certificate *does* support refusing, on purpose, to find out whether the
/// refusal was right.
///
/// That is the only way this app can ever learn. `CensoringLedger` records a refused turn with
/// admission probability zero because that is the truth — a deterministic threshold gives a refused
/// turn no chance at all, so no inverse-probability weight exists and the censoring can be measured
/// but never corrected. A turn admitted through this channel had a chance of `frequency`, and that
/// single fact is what makes its region reweightable.
///
/// **The constraints are the design, not decoration.**
///
/// - The **region** bounds how wrong the gate had to think the turn was. A turn scoring far above
///   the threshold is one the gate was confident about, and no budget reaches it.
/// - The **budget** is finite and spent in the currency the gate protects: each exploration is a
///   turn answered that the app had decided not to answer.
/// - The stage that uses this can only see a refusal from the conformal gate, because every other
///   gate returns before it runs. That is structural rather than a rule somebody has to remember.
enum ExplorationBudget {
    /// How often a reachable refusal is admitted. Becomes the admission probability of the whole
    /// band, drawn or not — having had a chance is what an inverse-probability weight is about.
    static let frequency = 0.20

    /// How far above the certified threshold this app is willing to explore, in nonconformity
    /// score. Everything beyond stays refused at any budget.
    static let reach = 0.15

    /// What one exploration costs, per unit of score above the threshold. Deliberately superlinear
    /// in nothing — the price is the depth, because the gate's own ranking is this app's only
    /// estimate of how bad answering would be.
    static let unitCost = 1.0

    /// Total exploration this app will pay for. Small on purpose: it buys a handful of labels, not
    /// a calibration set, and the stage says so rather than implying the certificate is within
    /// reach.
    static let budget = 3.0

    /// Conformal scores run the other way from a channel's.
    ///
    /// `ConformalGateKit` refuses a turn scoring *above* its threshold; a channel refuses one
    /// scoring *below*. Negating both puts them in one orientation and leaves the depth — the
    /// distance from the cut, which is all either side reasons about — unchanged. Stated rather
    /// than done quietly: an orientation flip that goes unnoticed explores the turns the gate was
    /// most comfortable with and calls them the refused ones.
    static func candidate(id: String, score: Double, threshold: Double) -> RefusalCandidate {
        RefusalCandidate(id: id, score: -score, threshold: -threshold)
    }

    static var region: ExplorationRegion? {
        try? ExplorationRegion(lowerBound: -reach, threshold: 0, frequency: frequency)
    }

    /// Held for the life of the app, and injected with a default exactly as `CensoringLedger` is,
    /// so two tests cannot spend each other's budget.
    static let shared: ExplorationChannel? = {
        guard let region else { return nil }
        return try? ExplorationChannel(
            region: region,
            budget: budget,
            costModel: LinearExplorationCost(unitCost: unitCost)
        )
    }()

    static let ledger = ExplorationLedger()
}
