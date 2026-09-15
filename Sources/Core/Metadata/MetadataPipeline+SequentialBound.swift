import EffectiveVoteKit
import Foundation
import SequentialBoundKit

extension MetadataPipeline {
    /// The "unhealthy" reading, passed as `SPRTBoundary.nullRate` — `SPRTBoundary`'s own doc
    /// comment names `nullRate` as "the regressed or unhealthy rate", so this app follows that
    /// convention rather than inventing its own. Chosen well below the healthy rate below so the
    /// two are easy to tell apart quickly; this stage pools the whole panel, not one gate's own
    /// history.
    static let sequentialBoundUnhealthyRate = 0.4

    /// The "healthy" reading, passed as `SPRTBoundary.alternativeRate` per that same convention.
    static let sequentialBoundHealthyRate = 0.7

    /// Passed as `SPRTBoundary.alpha`. Per `SPRTBoundary`'s own doc, `alpha` is the chance of
    /// favoring the alternative (healthy) when the null (unhealthy) is true — a **miss**: a real
    /// degradation read as healthy. Looser than the false-alarm budget below on purpose: missing
    /// a real degradation for one more turn costs less than crying wolf on a healthy session.
    static let sequentialBoundMissBudget = 0.10

    /// Passed as `SPRTBoundary.beta`. Per `SPRTBoundary`'s own doc, `beta` is the chance of
    /// favoring the null (unhealthy) when the alternative (healthy) is true — a **false alarm**.
    /// Kept tight because that call is the one a reader is likely to act on.
    static let sequentialBoundFalseAlarmBudget = 0.05

    /// The horizon `OperatingCharacteristicSolver` is asked to characterise this boundary at.
    ///
    /// Not the number of turns this app has actually observed — that varies session to session
    /// and would make the design reading a fact about traffic rather than about the boundary.
    /// Fifty is long enough for both rates above to plausibly resolve and short enough that full
    /// enumeration stays cheap on every call.
    static let sequentialBoundHorizon = 50

    /// Watches this app's own gate-affirmation stream for evidence its affirm rate has crossed
    /// from healthy to degraded, or the reverse, without waiting for a fixed sample size.
    func auditSequentialBound(
        trace: inout PipelineTrace,
        store: PanelHistoryStore = .shared
    ) async {
        await auditSequentialBound(trace: &trace, history: await store.history)
    }

    /// The same audit over a supplied history.
    ///
    /// `repeatedSuccess` pools this same panel but needs `k` verdicts from a gate before it will
    /// answer anything. SPRT's boundary is valid at *any* data-dependent stopping time, so this
    /// stage never needs a minimum to be honest — one cast verdict is a legitimate, if usually
    /// inconclusive, thing to watch. The only reading it cannot produce honestly is one from zero
    /// cast verdicts, because there is no stream to feed the monitor at all.
    func auditSequentialBound(
        trace: inout PipelineTrace,
        history: ObservationHistory,
        unhealthyRate: Double = MetadataPipeline.sequentialBoundUnhealthyRate,
        healthyRate: Double = MetadataPipeline.sequentialBoundHealthyRate,
        missBudget: Double = MetadataPipeline.sequentialBoundMissBudget,
        falseAlarmBudget: Double = MetadataPipeline.sequentialBoundFalseAlarmBudget,
        horizon: Int = MetadataPipeline.sequentialBoundHorizon
    ) async {
        guard !history.observations.isEmpty else {
            trace.record(.sequentialBound, .skipped(reason: Self.sequentialBoundNothingObserved()))
            return
        }
        let stream = Self.sequentialBoundStream(history)
        guard !stream.isEmpty else {
            trace.record(.sequentialBound, .noOp(reason: Self.sequentialBoundNoCastVerdicts(history)))
            return
        }
        await record(
            Self.sequentialBoundRead(
                stream,
                parameters: SequentialBoundParameters(
                    unhealthyRate: unhealthyRate, healthyRate: healthyRate,
                    missBudget: missBudget, falseAlarmBudget: falseAlarmBudget, horizon: horizon
                )
            ),
            into: &trace
        )
    }

    private func record(_ result: SequentialBoundResult, into trace: inout PipelineTrace) async {
        switch result {
        case let .refused(message):
            trace.record(.sequentialBound, .failed(message: message))
        case let .read(reading):
            trace.record(.sequentialBound, .ran(detail: Self.sequentialBoundDetail(reading)))
        }
    }

    // MARK: - reading the panel as one sequential stream

    /// Every cast verdict across every gate and every turn, oldest turn first and — within a
    /// turn — in `history.judges`' sorted order, so the stream this stage feeds the monitor is
    /// deterministic rather than dependent on dictionary iteration.
    ///
    /// Abstentions are dropped for the same reason `repeatedSuccess` drops them: a gate that
    /// abstained did not affirm or deny, and scoring it as either would invent a verdict nobody
    /// cast.
    static func sequentialBoundStream(_ history: ObservationHistory) -> [Bool] {
        var stream: [Bool] = []
        for observation in history.observations {
            for judge in history.judges {
                guard let verdict = observation.verdicts[judge], verdict.isCast else { continue }
                stream.append(verdict == .affirm)
            }
        }
        return stream
    }

    /// One reading: the monitor's state after the whole stream, when the boundary was first
    /// crossed if it was, and what the boundary promises by design at `horizon`.
    ///
    /// Not `Equatable`: `firstCrossing`'s tuple type cannot itself conform to `Equatable`, so
    /// deriving it here would mean hand-writing a `==` nothing in this stage's tests actually
    /// calls — dead code by this file's own siblings' standard, not a conformance to keep.
    struct SequentialBoundReading: Sendable {
        let unhealthyRate: Double
        let healthyRate: Double
        let missBudget: Double
        let falseAlarmBudget: Double
        let horizon: Int
        let trialCount: Int
        let successCount: Int
        let cumulativeLogLikelihoodRatio: Double
        let decision: SPRTDecision
        /// The 1-based trial index the boundary was first crossed at, and which way — `nil` when
        /// the stream never left `.continueSampling`.
        let firstCrossing: (trial: Int, decision: SPRTDecision)?
        /// The true, horizon-truncated miss rate: `P(read healthy | truly unhealthy)`.
        let exactMissRate: Double
        /// The true, horizon-truncated false-alarm rate: `P(read unhealthy | truly healthy)`.
        let exactFalseAlarmRate: Double
    }

    enum SequentialBoundResult: Sendable {
        case read(SequentialBoundReading)
        case refused(String)
    }

    /// The boundary configuration one read is run against, bundled so `sequentialBoundRead`
    /// stays under SwiftLint's parameter-count limit. `auditSequentialBound` still exposes each
    /// value as its own named, defaulted parameter — SwiftLint's `function_parameter_count`
    /// ignores parameters with a default, so that wrapper needs no bundling of its own.
    struct SequentialBoundParameters: Sendable {
        let unhealthyRate: Double
        let healthyRate: Double
        let missBudget: Double
        let falseAlarmBudget: Double
        let horizon: Int
    }

    static func sequentialBoundRead(
        _ stream: [Bool],
        parameters: SequentialBoundParameters
    ) async -> SequentialBoundResult {
        let boundary: SPRTBoundary
        do {
            boundary = try SPRTBoundary(
                nullRate: parameters.unhealthyRate, alternativeRate: parameters.healthyRate,
                alpha: parameters.missBudget, beta: parameters.falseAlarmBudget
            )
        } catch {
            return .refused(Self.sequentialBoundUnbuildable(parameters: parameters, error: error))
        }
        let characteristics: ExactOperatingCharacteristics
        do {
            characteristics = try OperatingCharacteristicSolver.solve(
                boundary: boundary, horizon: parameters.horizon
            )
        } catch {
            return .refused(Self.sequentialBoundUncharacterizable(horizon: parameters.horizon, error: error))
        }
        let monitor = SPRTMonitor(boundary: boundary)
        var firstCrossing: (trial: Int, decision: SPRTDecision)?
        for (index, success) in stream.enumerated() {
            let decision = await monitor.record(success: success)
            if firstCrossing == nil, decision != .continueSampling {
                firstCrossing = (index + 1, decision)
            }
        }
        return .read(
            SequentialBoundReading(
                unhealthyRate: parameters.unhealthyRate,
                healthyRate: parameters.healthyRate,
                missBudget: parameters.missBudget,
                falseAlarmBudget: parameters.falseAlarmBudget,
                horizon: parameters.horizon,
                trialCount: await monitor.trialCount,
                successCount: await monitor.successCount,
                cumulativeLogLikelihoodRatio: await monitor.cumulativeLogLikelihoodRatio,
                decision: await monitor.decision,
                firstCrossing: firstCrossing,
                exactMissRate: characteristics.exactTypeIError,
                exactFalseAlarmRate: characteristics.exactTypeIIError
            )
        )
    }

    // MARK: - the outcomes

    private static func sequentialBoundNothingObserved() -> String {
        "no turn observed yet; asking whether the affirm rate has crossed a boundary still needs "
            + "turns, and this panel has produced none"
    }

    private static func sequentialBoundNoCastVerdicts(_ history: ObservationHistory) -> String {
        "\(history.count) observed turn(s), but every gate abstained on every one of them; an "
            + "abstention is not a trial and there is no stream to watch"
    }

    private static func sequentialBoundUnbuildable(
        parameters: SequentialBoundParameters, error: Error
    ) -> String {
        "a boundary for unhealthy=\(sequentialBoundFormat(parameters.unhealthyRate, 2)) vs "
            + "healthy=\(sequentialBoundFormat(parameters.healthyRate, 2)) at miss budget="
            + "\(sequentialBoundFormat(parameters.missBudget, 2))/false-alarm budget="
            + "\(sequentialBoundFormat(parameters.falseAlarmBudget, 2)) was declined — \(error); no "
            + "substitute rates were invented for the ones that were asked about"
    }

    private static func sequentialBoundUncharacterizable(horizon: Int, error: Error) -> String {
        "the boundary built, but its exact operating characteristics at a horizon of \(horizon) "
            + "were declined — \(error); no reading was published without knowing what the boundary "
            + "actually promises"
    }

    // MARK: - the detail

    private static func sequentialBoundDetail(_ reading: SequentialBoundReading) -> String {
        [
            sequentialBoundValueLine(reading),
            sequentialBoundCrossingLine(reading),
            sequentialBoundDesignLine(reading)
        ].joined(separator: "; ")
    }

    private static func sequentialBoundValueLine(_ reading: SequentialBoundReading) -> String {
        "tests healthy=\(sequentialBoundFormat(reading.healthyRate, 2)) against "
            + "unhealthy=\(sequentialBoundFormat(reading.unhealthyRate, 2)) with a miss budget of "
            + "\(sequentialBoundFormat(reading.missBudget, 2)) and a false-alarm budget of "
            + "\(sequentialBoundFormat(reading.falseAlarmBudget, 2)); \(reading.trialCount) trial(s) "
            + "cast, \(reading.successCount) affirmed, cumulative log-likelihood ratio = "
            + "\(sequentialBoundFormat(reading.cumulativeLogLikelihoodRatio))"
    }

    private static func sequentialBoundCrossingLine(_ reading: SequentialBoundReading) -> String {
        guard let crossing = reading.firstCrossing else {
            return "no boundary crossed after \(reading.trialCount) trial(s); still watching"
        }
        return "crossed the boundary in favor of \(sequentialBoundLabel(crossing.decision)) at trial "
            + "\(crossing.trial) of \(reading.trialCount)"
    }

    private static func sequentialBoundDesignLine(_ reading: SequentialBoundReading) -> String {
        "by design, at a horizon of \(reading.horizon) trials this boundary's exact miss rate is "
            + "\(sequentialBoundFormat(reading.exactMissRate)) against a requested "
            + "\(sequentialBoundFormat(reading.missBudget, 2)), and its exact false-alarm rate is "
            + "\(sequentialBoundFormat(reading.exactFalseAlarmRate)) against a requested "
            + "\(sequentialBoundFormat(reading.falseAlarmBudget, 2))"
    }

    /// `.acceptAlternative` favors `alternativeRate`, which this stage always passes the healthy
    /// reading as; `.acceptNull` favors `nullRate`, always passed the unhealthy reading.
    static func sequentialBoundLabel(_ decision: SPRTDecision) -> String {
        switch decision {
        case .continueSampling: return "still watching"
        case .acceptNull: return "unhealthy"
        case .acceptAlternative: return "healthy"
        }
    }

    static func sequentialBoundFormat(_ value: Double, _ places: Int = 6) -> String {
        String(format: "%.\(places)f", value)
    }
}
