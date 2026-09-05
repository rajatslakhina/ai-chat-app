import EffectiveComparisonKit
import EffectiveVoteKit
import Foundation
import ObservedNullKit

extension MetadataPipeline {
    /// The panel this stage resamples: the same four gates `effectiveComparison` re-prices.
    static let observedNullJudgeCount = comparisonJudgeCount

    /// Checks the assumption `effectiveComparison` spends, against the panel's own grades.
    func auditObservedNull(
        trace: inout PipelineTrace,
        store: PanelHistoryStore = .shared
    ) async {
        await auditObservedNull(trace: &trace, history: await store.history)
    }

    /// The same audit over a supplied history.
    func auditObservedNull(trace: inout PipelineTrace, history: ObservationHistory) async {
        guard !history.observations.isEmpty else {
            trace.record(.observedNull, .skipped(reason: Self.nothingObservedYet()))
            return
        }
        do {
            let panel = try Self.panel(from: history)
            let family = AgreementFamily(observations: panel)
            let ledger = try ObservedNullLedger(family: family, level: Self.comparisonAlpha)
            // Deliberately not `try`: a pair that never disagreed has no bound to check, and
            // that must not suppress a bootstrap which needs no bound in the first place. The
            // audit being unanswerable is itself worth reporting, so it becomes nil rather than
            // an error that swallows the stage.
            let unattainable = try? await ledger.unattainableEntries(in: Self.structural(family))
            guard let threshold = try? await ledger.threshold(from: ObservedNullEstimator.standard) else {
                trace.record(.observedNull, .noOp(reason: Self.nothingToResample(family)))
                return
            }
            trace.record(
                .observedNull,
                .ran(detail: Self.observedDetail(
                    family, threshold: threshold, unattainable: unattainable?.count
                ))
            )
        } catch let error as ObservedNullError {
            trace.record(.observedNull, .noOp(reason: Self.cannotResample(error, history)))
        } catch {
            trace.record(.observedNull, .failed(message: "\(error)"))
        }
    }

    // MARK: - building the panel

    /// The panel as "did this gate affirm this turn", which is the `.verdictAgreement` basis
    /// `effectiveComparison` already measures on.
    ///
    /// Correctness would be the other candidate and is the wrong one here: most turns in this
    /// app carry no ground truth, so grading on it would make every gate constant and refuse
    /// every panel. Verdict agreement needs no label and is the same thing the sibling stage
    /// counts, which is what makes the two comparable.
    static func panel(from history: ObservationHistory) throws -> PanelObservations {
        let judges = history.judges
        let rows = history.observations.map { observation in
            judges.map { observation.verdicts[$0] == .affirm }
        }
        return try PanelObservations(judgeIdentifiers: judges.map(\.description), grades: rows)
    }

    /// The correlation matrix panel geometry implies, which is what `effectiveComparison` spends.
    static func structural(_ family: AgreementFamily) -> [[Double]] {
        var matrix = Array(
            repeating: Array(repeating: 0.0, count: family.size),
            count: family.size
        )
        for row in 0..<family.size {
            matrix[row][row] = 1
            for column in 0..<family.size where column != row {
                matrix[row][column] = family.pairs[row].overlaps(family.pairs[column]) ? 0.5 : 0
            }
        }
        return matrix
    }

    // MARK: - the outcomes

    /// Deliberately less than its sibling can say on a fresh install.
    ///
    /// `effectiveComparison` derives its correction from the panel's *shape* and so has a full
    /// answer before any turn has been observed. This stage exists to check that shape against
    /// what the gates actually did, so having nothing to say without observations is not a gap
    /// in it — it is the whole distinction between the two stages, and saying so is more useful
    /// than inventing a number.
    private static func nothingObservedYet() -> String {
        "no turn observed yet; this stage deliberately has nothing to say without grades — "
            + "its sibling's correction comes from the panel's shape, and checking that shape "
            + "is the one thing that cannot be done before the panel has graded anything"
    }

    /// A panel that exists but cannot be resampled, naming which gate and what would fix it.
    private static func cannotResample(_ error: ObservedNullError, _ history: ObservationHistory)
        -> String {
        "\(history.count) observed turn(s), but \(error.description); \(error.remedy)"
    }

    /// A family whose bootstrap produced no spread, which a threshold cannot be taken from.
    private static func nothingToResample(_ family: AgreementFamily) -> String {
        "\(family.observations.itemCount) turn(s) over \(family.size) pair(s) resample to a null "
            + "with no spread, so there is no tail to price and the fitted threshold stands"
    }

    /// What resampling found, next to what the fitted route assumes.
    private static func observedDetail(
        _ family: AgreementFamily,
        threshold: ObservedThreshold,
        unattainable: Int?
    ) -> String {
        [
            "\(family.observations.itemCount) turn(s), \(family.size) pair(s)",
            "resampling the panel prices its tail at " + format(threshold.ceiling.value)
                + ", worth " + format(threshold.effectiveCount)
                + " effective comparison(s) rather than \(family.size)",
            attainabilitySummary(family, unattainable: unattainable),
            "largest reading " + format(family.largestReading)
                + ", \(threshold.survivors(in: family).count) pair(s) survive"
        ].joined(separator: "; ")
    }

    /// Whether the correlation the design assumes is one these gates could produce.
    ///
    /// A `nil` count means the question has no answer on this page rather than a reassuring one:
    /// a Frechet bound needs two marginals with variance, and a pair of gates that never
    /// disagreed has none. That is the same degeneracy that leaves the fitted route with no
    /// matrix to fit, so it is reported rather than rounded to "fine".
    private static func attainabilitySummary(_ family: AgreementFamily, unattainable: Int?)
        -> String {
        guard let unattainable else {
            return "whether the structural matrix is reachable cannot be asked here — a pair of "
                + "gates never disagreed, which is also what would leave a fitted route with no "
                + "matrix at all, while resampling needs none"
        }
        guard unattainable > 0 else {
            return "every entry of the structural matrix is reachable at these agreement rates, "
                + "so the assumption underneath the fitted route holds here"
        }
        return "\(unattainable) entry(s) of the structural matrix sit above what these agreement "
            + "rates admit, so the fitted route is drawing from a distribution no panel with "
            + "these gates could produce"
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}
