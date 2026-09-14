import EffectiveVoteKit
import Foundation
import RepeatedSuccessKit

extension MetadataPipeline {
    /// How many attempts in a row the stage asks about. Five is the run length the app's own
    /// retry surface can reach, so it is the number a reader would actually act on.
    static let repeatedSuccessRepetitions = 5

    /// The smallest number of cast verdicts a gate needs before it can support a run of that
    /// length. A gate with fewer attempts than repetitions contributes nothing and is dropped.
    static let repeatedSuccessMinimumAttempts = repeatedSuccessRepetitions

    /// The confidence the panel-wide bound is drawn at.
    static let repeatedSuccessConfidence = 0.95

    /// Measures whether this app's pooled gate affirm rate can answer a question about more
    /// than one turn at a time.
    func auditRepeatedSuccess(
        trace: inout PipelineTrace,
        store: PanelHistoryStore = .shared
    ) async {
        await auditRepeatedSuccess(trace: &trace, history: await store.history)
    }

    /// The same audit over a supplied history.
    ///
    /// Every other stage that reads this panel quotes gate behaviour as a single rate. That rate
    /// is a sufficient statistic for exactly one question — how often a gate affirms one turn —
    /// and stops being one the moment the question is about a run. Because `x^k` is convex,
    /// pooling and then raising to a power understates an all-of-k answer and overstates an
    /// any-of-k one, and the size of that error is not a nuisance term: on a balanced panel at
    /// `k = 2` it is exactly the dispersion the gates show in excess of binomial noise.
    ///
    /// So this stage reads the gates as a panel of repeated attempts — one gate is one task, the
    /// turns it cast a verdict on are its attempts, the turns it affirmed are its successes — and
    /// reports both answers with the gap between them. A gap near zero means the gates behave as
    /// one population and the pooled rate is safe to power up. A large one means they do not, and
    /// no single rate can stand in for them.
    ///
    /// Like its metadata siblings it raises no `Refusal`: a reading the panel cannot support is
    /// not a reason to withhold an answer the user has already paid for.
    func auditRepeatedSuccess(
        trace: inout PipelineTrace,
        history: ObservationHistory,
        repetitions: Int = MetadataPipeline.repeatedSuccessRepetitions,
        level: Double = MetadataPipeline.repeatedSuccessConfidence
    ) async {
        guard !history.observations.isEmpty else {
            trace.record(.repeatedSuccess, .skipped(reason: Self.repeatedSuccessNothingObserved()))
            return
        }
        let rows = Self.repeatedSuccessRows(history)
        // `max()` is nil exactly when no gate cast a verdict, so the two guards are one question.
        guard let longest = rows.map(\.attempts).max() else {
            trace.record(.repeatedSuccess, .noOp(reason: Self.repeatedSuccessNoCastVerdicts(history)))
            return
        }
        guard longest >= repetitions else {
            trace.record(
                .repeatedSuccess,
                .noOp(reason: Self.repeatedSuccessTooShort(
                    gates: rows.count, longest: longest, repetitions: repetitions
                ))
            )
            return
        }
        await record(
            Self.repeatedSuccessRead(rows, repetitions: repetitions, level: level),
            rows: rows, history: history, into: &trace
        )
    }

    private func record(
        _ result: RepeatedSuccessResult,
        rows: [TaskAttempts],
        history: ObservationHistory,
        into trace: inout PipelineTrace
    ) async {
        switch result {
        case let .refused(message):
            trace.record(.repeatedSuccess, .failed(message: message))
        case let .read(reading):
            trace.record(
                .repeatedSuccess,
                .ran(detail: Self.repeatedSuccessDetail(reading, rows: rows, history: history))
            )
        }
    }

    // MARK: - reading the gates as repeated attempts

    /// One gate, as a task with repeated attempts: cast verdicts are attempts, affirms succeed.
    ///
    /// Abstentions are dropped rather than counted as failures, for the same reason the rest of
    /// this app drops them — a gate that abstained did not fail, it declined to answer, and
    /// scoring it as a failure would invent a verdict nobody cast.
    static func repeatedSuccessRows(_ history: ObservationHistory) -> [TaskAttempts] {
        history.judges.compactMap { judge in
            var attempts = 0
            var successes = 0
            for observation in history.observations {
                guard let verdict = observation.verdicts[judge], verdict.isCast else { continue }
                attempts += 1
                if verdict == .affirm { successes += 1 }
            }
            guard attempts > 0 else { return nil }
            return TaskAttempts(identifier: judge.rawValue, attempts: attempts, successes: successes)
        }
    }

    /// One reading: both questions at the stage's repetition count, with what the gap measures.
    struct RepeatedSuccessReading: Sendable, Equatable {
        let repetitions: Int
        let gateCount: Int
        let gatesUsed: Int
        let gatesDropped: Int
        let pooledRate: Double
        let allNaive: Double
        let allUnbiased: Double
        let anyNaive: Double
        let anyUnbiased: Double
        /// `nil` when the gates did not all rule on the same number of turns, where the closed
        /// form for the gap has no meaning.
        let excessDispersion: Double?
        let panelBound: Double
        let level: Double
    }

    /// Two outcomes, and both are reachable from the audit itself.
    ///
    /// There is deliberately no third "panel could not be built" case: gate identities come from
    /// `history.judges`, which is a sorted set, so the duplicate-identifier failure `AttemptPanel`
    /// guards against cannot arise from `repeatedSuccessRows`. Keeping an arm the real entry point
    /// can never take would be an untestable branch pretending to be a safety net.
    enum RepeatedSuccessResult: Sendable {
        case read(RepeatedSuccessReading)
        case refused(String)
    }

    static func repeatedSuccessRead(
        _ rows: [TaskAttempts],
        repetitions: Int,
        level: Double
    ) async -> RepeatedSuccessResult {
        guard let panel = try? AttemptPanel(rows) else {
            return .refused(Self.repeatedSuccessUnbuildable(rows))
        }
        let estimator = RepeatedSuccessEstimator(panel: panel)
        do {
            let all = try await estimator.allSucceed(repetitions: repetitions)
            let any = try await estimator.anySucceeds(repetitions: repetitions)
            let dispersion = await estimator.dispersion()
            let bound = try ReliabilityBound.panelMeanLowerBound(
                estimate: all.unbiased, taskCount: all.tasksUsed, level: level
            )
            return .read(
                RepeatedSuccessReading(
                    repetitions: repetitions,
                    gateCount: panel.taskCount,
                    gatesUsed: all.tasksUsed,
                    gatesDropped: all.tasksDropped,
                    pooledRate: all.pooledRate,
                    allNaive: all.pooled,
                    allUnbiased: all.unbiased,
                    anyNaive: any.pooled,
                    anyUnbiased: any.unbiased,
                    excessDispersion: dispersion?.excessDispersion,
                    panelBound: bound,
                    level: level
                )
            )
        } catch {
            return .refused(Self.repeatedSuccessUnreadable(rows, repetitions: repetitions, error: error))
        }
    }

    // MARK: - the outcomes

    private static func repeatedSuccessNothingObserved() -> String {
        "no turn observed yet; asking whether a gate affirms five turns in a row still needs "
            + "turns, and this panel has produced none"
    }

    private static func repeatedSuccessNoCastVerdicts(_ history: ObservationHistory) -> String {
        "\(history.count) observed turn(s), but every gate abstained on every one of them; an "
            + "abstention is not a failed attempt and is not counted as one"
    }

    private static func repeatedSuccessTooShort(gates: Int, longest: Int, repetitions: Int) -> String {
        "\(gates) gate(s) on this panel and the busiest cast \(longest) verdict(s); a run of "
            + "\(repetitions) cannot be drawn from any of them, so no answer was invented from a "
            + "shorter one"
    }

    private static func repeatedSuccessUnbuildable(_ rows: [TaskAttempts]) -> String {
        "\(rows.count) gate row(s) did not form a panel; two gates share an identity, or a count "
            + "is impossible, and neither is something this stage will quietly repair"
    }

    private static func repeatedSuccessUnreadable(
        _ rows: [TaskAttempts], repetitions: Int, error: Error
    ) -> String {
        "\(rows.count) gate(s) and a run of \(repetitions) was declined — \(error); no shorter "
            + "run was substituted for the one that was asked about"
    }

    // MARK: - the detail

    private static func repeatedSuccessDetail(
        _ reading: RepeatedSuccessReading,
        rows: [TaskAttempts],
        history: ObservationHistory
    ) -> String {
        var parts = [
            "\(history.count) turn(s) across \(reading.gateCount) gate(s), "
                + "\(reading.gatesUsed) of them long enough for a run of \(reading.repetitions)"
                + (reading.gatesDropped > 0 ? " and \(reading.gatesDropped) dropped" : "")
        ]
        parts.append(repeatedSuccessValueLine(reading))
        parts.append(repeatedSuccessDispersionLine(reading))
        parts.append(repeatedSuccessBoundLine(reading))
        return parts.joined(separator: "; ")
    }

    private static func repeatedSuccessValueLine(_ reading: RepeatedSuccessReading) -> String {
        func format(_ value: Double) -> String { repeatedSuccessFormat(value) }
        return "pooled affirm rate = " + format(reading.pooledRate) + ", so the naive all-of-"
            + "\(reading.repetitions) is " + format(reading.allNaive) + " against an unbiased "
            + format(reading.allUnbiased) + ", and the naive any-of-\(reading.repetitions) is "
            + format(reading.anyNaive) + " against an unbiased " + format(reading.anyUnbiased)
    }

    private static func repeatedSuccessDispersionLine(_ reading: RepeatedSuccessReading) -> String {
        guard let excess = reading.excessDispersion else {
            return "the gates did not all rule on the same number of turns, so the closed form for "
                + "the gap was not quoted rather than quoted on a design this panel does not have"
        }
        let rendered = repeatedSuccessFormat(excess)
        guard excess > 0 else {
            return "excess dispersion = " + rendered + ", so these gates sit within binomial noise "
                + "of one another and the pooled rate is safe to raise to a power here"
        }
        return "excess dispersion = " + rendered + ", so the gates are NOT one population — the "
            + "pooled rate understates a run and overstates a best-of, and no single rate can "
            + "stand in for them at this k"
    }

    private static func repeatedSuccessBoundLine(_ reading: RepeatedSuccessReading) -> String {
        "the distribution-free bound across gates puts all-of-\(reading.repetitions) at no less "
            + "than " + repeatedSuccessFormat(reading.panelBound) + " with "
            + repeatedSuccessFormat(reading.level, 2) + " confidence; it assumes nothing about how "
            + "the gate rates are spread, which is the assumption a single-gate interval cannot make"
    }

    static func repeatedSuccessFormat(_ value: Double, _ places: Int = 6) -> String {
        String(format: "%.\(places)f", value)
    }
}
