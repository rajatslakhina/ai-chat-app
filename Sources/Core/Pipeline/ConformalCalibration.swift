import AbstentionPolicyKit
import ConformalGateKit
import Foundation

/// Turns one turn's reservations into a nonconformity score, and one finished turn into the label
/// that score needs.
///
/// The pairing is the whole idea. Every gate in this pipeline judges the *question* before the
/// model is paid; four post-model stages judge the *answer* afterwards. A turn this app answered
/// and then refused on grounding, consistency, citation or decontextualization is a turn where
/// answering was wrong — and that verdict, arriving on the far side of the model call, is exactly
/// the ground truth a pre-model gate can never produce for itself.
enum ConformalCalibration {
    /// One in twenty, which needs nineteen labelled turns before it certifies anything.
    static let gate = ConformalGate(budget: .oneInTwenty)

    /// The stages whose refusal means the answer was wrong.
    ///
    /// `guardrailOutput` is deliberately not here. It refuses over PII in the output, which is a
    /// privacy failure rather than a truthfulness one, and nothing about the retrieved corpus
    /// predicts it. Labelling those turns wrong would ask the gate to learn a signal that is not
    /// in its input, and it would learn noise instead.
    static let verificationStages: Set<PipelineStage> = [
        .grounding, .claimConsistency, .citationBinding, .claimDecontextualization
    ]

    /// Higher is more suspect, which is the direction every conformal result is stated in.
    ///
    /// `nil` when no gate filed anything, and that is not a score of zero. A turn carrying no
    /// retrieved evidence had nothing for the four gates to read, so there is no reading to be
    /// confident *or* suspicious about — and feeding it in as a confident zero would fill the
    /// calibration set with ordinary conversation and certify a threshold against traffic the
    /// gate never sees.
    static func score(for reservations: [AbstentionSignal]) -> Double? {
        guard !reservations.isEmpty else { return nil }
        let total = reservations.reduce(0.0) { $0 + weight($1.reading) }
        return total / Double(reservations.count)
    }

    /// A refusal is the top of the scale. `unavailable` sits above a low concern because a judge
    /// that could not rule tells you less than one that ruled and found something small.
    private static func weight(_ reading: SignalReading) -> Double {
        if reading.isRefusal { return 1.0 }
        if reading.isUnavailable { return 0.6 }
        if let severity = reading.concernSeverity { return 0.4 + 0.1 * Double(severity.rawValue) }
        return 0.0
    }

    /// Whether answering this turn turned out to be wrong, judged by stages that read the answer.
    static func answeringWasWrong(_ trace: PipelineTrace) -> Bool {
        trace.records.contains { verificationStages.contains($0.stage) && $0.outcome.isRefusal }
    }

    /// The labelled point for a finished turn, or `nil` when the turn cannot carry one.
    ///
    /// Two turns in three produce nothing here, and both absences are correct: a turn with no
    /// reservations has no score, and a turn where no verification stage ran has no verdict to
    /// label it with. A point invented for either would be a measurement of nothing.
    static func point(id: String, trace: PipelineTrace) -> CalibrationPoint? {
        guard let score = score(for: trace.reservations) else { return nil }
        guard trace.records.contains(where: { verificationStages.contains($0.stage) }) else { return nil }
        return CalibrationPoint(id: id, score: score, wasWrong: answeringWasWrong(trace))
    }
}

/// Where labelled turns accumulate between sends.
///
/// A cross-turn ledger cannot live inside one turn, so this is held for the life of the app and
/// injected with a default rather than reached for globally — tests pass their own, which is also
/// the only way two tests can avoid certifying against each other's turns.
///
/// The bias worth stating: **this app only ever learns about turns it answered.** A turn the gates
/// refused is never sent, never verified, and never labelled, so the calibration set is drawn from
/// the traffic that got through rather than from all traffic. The certificate is honest about the
/// population it was calibrated on, and that population is not the same as the one the gate meets.
enum ConformalLedger {
    static let shared = CalibrationStore(certifier: ConformalCalibration.gate, capacity: 256)
}
