import CensoredFeedbackConformal
import CensoredFeedbackKit
import ConformalGateKit
import Foundation

extension PreModelPipeline {
    /// Decides whether the conformal gate's promise reaches the traffic it is about to judge.
    ///
    /// **This is the only stage in this pipeline whose effect is to stop a gate refusing**, and it
    /// is allowed that for exactly one reason. The gate above certifies a bound over the population
    /// it was calibrated on, and this app can only ever calibrate on turns it *answered* — a
    /// refused turn is never sent, never verified and never labelled. So the certificate is
    /// arithmetically correct about a population that is not the one the gate meets, and nothing
    /// inside the certificate can notice, because its empirical loss was summed over precisely the
    /// requests that got through.
    ///
    /// It files no reservation and produces no refusal of its own. It changes what the stage below
    /// is permitted to do and never what any stage decides, which is the same rule
    /// `signalDependence` follows one gate earlier.
    ///
    /// Its ordinary outcome while the gate is uncalibrated is `.skipped`: with no certificate there
    /// is nothing to qualify, and saying so beats appearing to work.
    nonisolated func qualifyCertifiedRisk(
        ledger: CalibrationStore,
        censoring: FeedbackLedger?,
        trace: inout PipelineTrace
    ) async -> CertificateSupport? {
        let outcome = await ledger.certificate()
        guard outcome.certificate != nil else {
            let reason = "no certificate to qualify — \(outcome.summary)"
            trace.record(.censoredFeedback, .skipped(reason: reason))
            return nil
        }
        guard let censoring else {
            trace.record(.censoredFeedback, .skipped(reason: "no decision log configured"))
            return nil
        }
        guard let audit = try? await censoring.audit() else {
            trace.record(.censoredFeedback, .failed(message: "the decision log could not be audited"))
            return nil
        }
        let support = CertificateQualifier().qualify(outcome, against: audit)
        trace.record(.censoredFeedback, Self.qualificationOutcome(support, audit: audit))
        return support
    }

    /// What the audit did, told apart from what it found.
    ///
    /// Both arms are `.ran`: qualifying a certificate is work whichever way it comes out, and a
    /// withdrawal is the more consequential of the two. Reporting the withdrawal as `.noOp` would
    /// make the one turn where this stage changed the pipeline look like the turns where it did
    /// nothing.
    private static func qualificationOutcome(
        _ support: CertificateSupport,
        audit: CensoringAudit
    ) -> StageOutcome {
        let censored = audit.profile.censoredCount
        let seen = audit.profile.recordCount
        guard support.allowsEnforcement else {
            return .ran(
                detail: "enforcement withdrawn — \(support.summary); "
                    + "\(censored) of \(seen) decisions unlabelled, \(audit.exploration.summary)"
            )
        }
        return .ran(detail: "certificate holds over all \(seen) decisions — \(support.summary)")
    }

    /// Records what happened to one turn, so the next turn's audit knows about it.
    ///
    /// A turn with no reservations is not recorded at all, which matches the rule
    /// `ConformalCalibration.point` follows: nothing scored it, so it is not in the population the
    /// certificate is about. Recording it as a clean refusal would fill the log with ordinary
    /// conversation and report a censoring rate for traffic the gate never sees.
    nonisolated func recordRefusedTurn(
        ledger: CalibrationStore,
        censoring: FeedbackLedger?,
        trace: PipelineTrace
    ) async {
        guard let censoring, let score = ConformalCalibration.score(for: trace.reservations) else { return }
        let threshold = await ledger.certificate().certificate?.threshold
        let id = "refused-\(await censoring.count)"
        try? await censoring.record(
            CensoringFeedback.refused(id: id, score: score, threshold: threshold)
        )
    }
}
