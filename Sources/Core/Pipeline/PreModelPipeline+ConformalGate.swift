import AbstentionPolicyKit
import ConformalGateAbstention
import ConformalGateKit
import Foundation

extension PreModelPipeline {
    /// Refuses a turn whose reservations score outside a threshold this app actually derived.
    ///
    /// Runs after the arbiter, and last of the free stages, because it needs the reservations in
    /// their final deflated form. It is the only gate here whose threshold is not a number
    /// somebody chose: `concurringOrigins: 2` above it was picked because it seemed reasonable,
    /// and nothing in this app could ever say what it bought.
    ///
    /// **It files no reservation, and that is deliberate.** Its score is computed *from* the four
    /// gates' readings, so a reservation of its own would be their opinion arriving a second time
    /// — exactly the entanglement `signalDependence` runs immediately upstream to catch. It
    /// refuses on its own authority or it says nothing.
    ///
    /// Its ordinary outcome for a long time will be `.noOp`, because nineteen labelled turns have
    /// to accumulate before one-in-twenty can be certified at all. Saying so beats appearing to
    /// work: a gate that lets everything through because it is uncalibrated looks identical, from
    /// the outside, to one that examined the turn and approved it.
    nonisolated func gateOnCertifiedRisk(
        ledger: CalibrationStore,
        trace: inout PipelineTrace
    ) async -> Refusal? {
        guard let score = ConformalCalibration.score(for: trace.reservations) else {
            trace.record(.conformalGate, .skipped(reason: "no gate filed a reading to score"))
            return nil
        }

        let outcome = await ledger.certificate()
        let reading = ConformalSignalMapper().reading(forScore: score, under: outcome)
        // One guard rather than two. Only a certified outcome can produce `.refuse`, so a second
        // `guard let certificate` would carry an else-branch no input could reach — a branch that
        // reads as covered because the line above it is.
        guard case let .refuse(detail) = reading, let certificate = outcome.certificate else {
            trace.record(.conformalGate, Self.nonRefusal(reading: reading, score: score))
            return nil
        }

        let refusal = Self.riskRefusal(detail: detail, certificate: certificate)
        trace.record(.conformalGate, .refused(refusal))
        return refusal
    }

    /// Every path that is not a refusal, told apart.
    ///
    /// `unavailable` and `clear` are both "this turn continues" and they are not the same event.
    /// One is a threshold that examined the score and admitted it; the other is a gate with no
    /// threshold to examine it with.
    private static func nonRefusal(reading: SignalReading, score: Double) -> StageOutcome {
        let scored = String(format: "%.2f", score)
        guard reading.isUnavailable else {
            return .ran(detail: "score \(scored) is inside the certified threshold")
        }
        return .noOp(reason: "score \(scored) not judged — \(reading.detail)")
    }

    /// The one refusal this stage makes.
    ///
    /// It quotes the bound rather than only the threshold, because "above 0.33" tells a user
    /// nothing while "this app has measured that answering turns like this one is wrong more
    /// often than one time in twenty" is a claim they can disagree with. The recovery is
    /// Retrieval for the same reason the arbiter's is: every reading behind the score is a
    /// statement about the corpus that was retrieved, which is the one thing the user can change.
    private static func riskRefusal(detail: String, certificate: Certificate) -> Refusal {
        let bound = String(format: "%.1f%%", certificate.certifiedBound * 100)
        let evidence = "Measured over \(certificate.calibrationSize) answered turns, the risk of "
            + "answering below this threshold is held at or under \(bound)."
        return Refusal(
            stage: .conformalGate,
            headline: "This one looks like the turns that come back wrong",
            explanation: "The checks that read your sources scored this turn outside the range this "
                + "app has certified. \(detail). \(evidence)",
            recovery: .openSettings(field: "Retrieval")
        )
    }
}
