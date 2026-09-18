import Foundation
import SplitContrastKit

extension MetadataPipeline {
    /// Miscoverage budget for the whole sequence of looks at the channel's admission rate.
    ///
    /// The same 0.05 its measurement neighbours spend, so a reader comparing their lines is
    /// comparing methods rather than configurations.
    static let splitContrastAlpha = 0.05

    /// Audits the exploration channel's draw against the frequency it was configured with.
    func auditSplitContrast(
        trace: inout PipelineTrace,
        log: ExplorationDrawLog = ExplorationBudget.draws
    ) async {
        let draws = await log.draws
        auditSplitContrast(trace: &trace, draws: draws)
    }

    /// The same audit over a supplied sequence of draws, `true` for an admission.
    ///
    /// `SplitContrastKit` exists to compare two arms under a randomised split, and it rests on
    /// one assumption before any other: that the split really routes at the probability the design
    /// declared. This app has exactly one randomised split — the exploration channel, which admits
    /// an eligible refused turn with probability `ExplorationBudget.frequency` — and every
    /// inverse-probability weight `censoredFeedback` applies to an explored turn is `1 / frequency`.
    /// So the package's assignment check gets a real job here: whether the channel is delivering
    /// the frequency those weights assume.
    func auditSplitContrast(
        trace: inout PipelineTrace,
        draws: [Bool],
        declared: Double = ExplorationBudget.frequency,
        alpha: Double = MetadataPipeline.splitContrastAlpha
    ) {
        guard !draws.isEmpty else {
            trace.record(.splitContrast, .skipped(reason: Self.splitContrastNothingDrawn()))
            return
        }
        switch Self.splitContrastRead(draws, declared: declared, alpha: alpha) {
        case let .read(reading):
            trace.record(.splitContrast, .ran(detail: Self.splitContrastDetail(reading)))
        case let .refused(message):
            trace.record(.splitContrast, .failed(message: message))
        }
    }

    /// What the draws say about the frequency the channel actually admits at.
    struct SplitContrastReading: Sendable {
        let declared: Double
        let alpha: Double
        let draws: Int
        let admitted: Int
        /// Admissible values of the channel's true admission rate after every draw.
        let bounds: SplitBounds
        /// The 1-based draw at which the declared frequency was first ruled out, `nil` while it
        /// never has been.
        let firstMismatchDraw: Int?
        /// Whether the latest look still admits the declared frequency. Reported beside the first
        /// mismatch rather than folded into it, because each look is solved from the counts alone
        /// and a later one can re-admit what an earlier one ruled out.
        let declaredAdmissibleNow: Bool
    }

    enum SplitContrastResult: Sendable {
        case read(SplitContrastReading)
        case refused(String)
    }

    /// Replays the draws through the package's anytime-valid assignment check.
    ///
    /// An admission is arm A and an eligible turn not drawn is arm B. The assignment check reads
    /// arm totals only, so each draw is folded in with a placeholder outcome — there is no pass
    /// or fail to record for a turn nobody answered, and pretending otherwise is what the detail's
    /// last line refuses to do.
    static func splitContrastRead(_ draws: [Bool], declared: Double, alpha: Double) -> SplitContrastResult {
        do {
            let check = try AssignmentCheck(declaredProbability: declared, alpha: alpha)
            var counts = SplitCounts.empty
            var firstMismatch: Int?
            for admitted in draws {
                counts = counts.appending(SplitOutcome(arm: admitted ? .a : .b, succeeded: false))
                if firstMismatch == nil, check.rejectsDeclared(counts) {
                    firstMismatch = counts.trials
                }
            }
            let reading = check.reading(for: counts)
            return .read(
                SplitContrastReading(
                    declared: declared,
                    alpha: alpha,
                    draws: counts.trials,
                    admitted: counts.aTrials,
                    bounds: reading.bounds,
                    firstMismatchDraw: firstMismatch,
                    declaredAdmissibleNow: reading.declaredAdmissible
                )
            )
        } catch {
            return .refused(Self.splitContrastDeclined(declared: declared, error: error))
        }
    }

    // MARK: - the outcomes

    private static func splitContrastNothingDrawn() -> String {
        "the exploration channel has not reached its draw yet; auditing the frequency it admits at "
            + "needs at least one eligible refused turn, and this session has produced none"
    }

    private static func splitContrastDeclined(declared: Double, error: Error) -> String {
        "an assignment audit of the exploration channel at a declared frequency of "
            + "\(splitContrastFormat(declared, 2)) was declined — \(error); no reading was published "
            + "under a configuration the check did not accept"
    }

    // MARK: - the detail

    private static func splitContrastDetail(_ reading: SplitContrastReading) -> String {
        [
            splitContrastRateLine(reading),
            splitContrastVerdictLine(reading),
            splitContrastScopeLine()
        ].joined(separator: "; ")
    }

    private static func splitContrastRateLine(_ reading: SplitContrastReading) -> String {
        "the exploration channel reached its draw on \(reading.draws) eligible turn(s) and admitted "
            + "\(reading.admitted), a realised rate of "
            + "\(splitContrastFormat(Double(reading.admitted) / Double(reading.draws))) against a "
            + "declared frequency of \(splitContrastFormat(reading.declared, 2)); the true admission "
            + "rate lies in [\(splitContrastFormat(reading.bounds.lower)), "
            + "\(splitContrastFormat(reading.bounds.upper))] at a miscoverage budget of "
            + "\(splitContrastFormat(reading.alpha, 2)) spent once across every draw"
    }

    private static func splitContrastVerdictLine(_ reading: SplitContrastReading) -> String {
        let declared = splitContrastFormat(reading.declared, 2)
        guard let draw = reading.firstMismatchDraw else {
            return "\(declared) is still admissible after \(reading.draws) draw(s), so the "
                + "1/\(declared) inverse-probability weight every explored turn carries into "
                + "censoredFeedback has not been contradicted"
        }
        let now = reading.declaredAdmissibleNow
            ? "although the latest look re-admits it"
            : "and it is still excluded"
        return "\(declared) stopped being admissible at draw \(draw) of \(reading.draws), \(now) — "
            + "the 1/\(declared) weight every explored turn carries into censoredFeedback rests on a "
            + "frequency this channel did not deliver, and no correction is owed for the looks before it"
    }

    /// The half of the package this app cannot use, said rather than faked.
    private static func splitContrastScopeLine() -> String {
        "SplitContrastKit's difference-of-rates half has nothing to read here: a turn the channel "
            + "did not draw stays refused and is never answered, so there is no second arm with a "
            + "pass rate to subtract, and only the assignment the whole package rests on is audited"
    }

    static func splitContrastFormat(_ value: Double, _ places: Int = 6) -> String {
        String(format: "%.\(places)f", value)
    }
}
