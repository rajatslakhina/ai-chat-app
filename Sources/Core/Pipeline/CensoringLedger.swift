import AbstentionPolicyKit
import CensoredFeedbackKit
import Foundation

/// Turns one turn's fate into the record the conformal ledger can never hold.
///
/// `ConformalCalibration` builds a labelled point for every turn this app *answered*. That is the
/// only turn it can build one for: a turn the gates refused was never sent, never verified and
/// never graded. So the calibration set is drawn from the traffic that got through, and the
/// certificate derived from it is a promise about that traffic rather than about all of it.
///
/// This records the other half. A refused turn has no label and it is not nothing — it is a known
/// gap, and the size of the gap is what decides whether the certificate's promise reaches the
/// requests the gate actually meets.
enum CensoringFeedback {
    /// The same budget the gate certifies at, so `ExplorationPlan` prices the fix in the same
    /// inequality the gate refuses on.
    static let budget = 0.05

    /// A turn this app answered and then verified. The only arm carrying evidence.
    static func answered(id: String, wasWrong: Bool) -> FeedbackRecord {
        FeedbackRecord(id: id, admissionProbability: 1, observation: .observed(wasWrong ? 1 : 0))
    }

    /// A turn a gate refused, with the arm decided by the certificate that would have judged it.
    ///
    /// Above the threshold the loss is pinned at zero by the loss definition: the conformal gate
    /// would not have answered this turn either, so it cannot contribute to "answered and wrong"
    /// whatever the answer would have been. At or below it, the gate *would* have answered — and
    /// nobody ever found out whether that was a mistake. That turn is the censoring.
    ///
    /// With no certificate yet there is no threshold to compare against, and a guess either way
    /// would be an invented fact. Unknown is the honest arm.
    static func refused(id: String, score: Double, threshold: Double?) -> FeedbackRecord {
        let observation: LossObservation
        if let threshold, score > threshold {
            observation = .determined(0)
        } else {
            observation = .censored
        }
        return FeedbackRecord(id: id, admissionProbability: 0, observation: observation)
    }
}

/// Where the decision log accumulates between turns.
///
/// Held for the life of the app and injected with a default, exactly as `ConformalLedger` is, so
/// two tests cannot audit each other's turns. The capacity matches the calibration store's: an
/// audit of a window wider than the certificate's would report censoring in traffic the
/// certificate never saw.
///
/// Optional rather than force-constructed. `lossBound: 1, budget: 0.05, capacity: 256` is valid
/// and this is never `nil` in the app — but a crash in the startup path to avoid one `guard` is a
/// bad trade, and the stage below has to handle an absent ledger anyway for the tests that pass
/// one deliberately.
enum CensoringLedger {
    static let shared: FeedbackLedger? = {
        let auditor = try? CensoringAuditor(lossBound: 1, budget: CensoringFeedback.budget)
        return auditor.flatMap { FeedbackLedger(capacity: 256, auditor: $0) }
    }()
}
