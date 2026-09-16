import ConfidenceSequenceKit
import EffectiveVoteKit
import Foundation

extension MetadataPipeline {
    /// Total miscoverage budget for the **whole sequence** of readings, not for one of them.
    ///
    /// That is the entire reason this stage exists beside `sequentialBound`: a fixed-sample
    /// interval recomputed after every turn spends its budget again on every look, and this
    /// pipeline looks again after every turn. Ville's inequality bounds the chance the mixture
    /// martingale *ever* crosses `1 / alpha` by `alpha`, so the budget below is spent once no
    /// matter how many turns the session runs to.
    static let confidenceSequenceAlpha = 0.05

    /// The advertised pass rate the interval is asked about.
    ///
    /// Taken from `sequentialBound` rather than invented. The two stages read the same pooled
    /// stream, and a separate number here would turn a comparison of two *methods* into a
    /// comparison of two configurations.
    static let confidenceSequenceReferenceRate = MetadataPipeline.sequentialBoundHealthyRate

    /// The degraded reading, used only to price detection power — never to decide anything.
    ///
    /// A confidence sequence needs no second hypothesis to produce its interval. This one is
    /// handed to the solver as a *truth* to ask "would these looks have caught it", which is the
    /// same solver call the miscoverage audit makes with a different argument.
    static let confidenceSequenceDegradedRate = MetadataPipeline.sequentialBoundUnhealthyRate

    /// The longest horizon the exact audit is run to.
    ///
    /// `ExclusionSolver` enumerates an `O(horizon²)` lattice and evaluates the martingale at
    /// every state, so auditing at the observed horizon alone would make a background task's cost
    /// grow with session length without bound. Sixty covers a long chat session's pooled panel,
    /// and the detail line always names the horizon actually audited alongside the number of
    /// looks actually taken, so a capped audit is never reported as an uncapped one.
    static let confidenceSequenceAuditCeiling = 60

    /// Publishes a time-uniform interval for this app's own gate pass rate, off the same pooled
    /// stream `sequentialBound` watches.
    func auditConfidenceSequence(
        trace: inout PipelineTrace,
        store: PanelHistoryStore = .shared
    ) async {
        await auditConfidenceSequence(trace: &trace, history: await store.history)
    }

    /// The same audit over a supplied history.
    ///
    /// The stream is `sequentialBoundStream`'s, not a second pooling of the same panel: two
    /// stages reading the same verdicts through two orderings would be two answers about two
    /// different sessions, and the whole point of putting an interval next to a boundary is that
    /// they are answers about one.
    func auditConfidenceSequence(
        trace: inout PipelineTrace,
        history: ObservationHistory,
        alpha: Double = MetadataPipeline.confidenceSequenceAlpha,
        referenceRate: Double = MetadataPipeline.confidenceSequenceReferenceRate,
        degradedRate: Double = MetadataPipeline.confidenceSequenceDegradedRate,
        auditCeiling: Int = MetadataPipeline.confidenceSequenceAuditCeiling
    ) async {
        guard !history.observations.isEmpty else {
            trace.record(.confidenceSequence, .skipped(reason: Self.confidenceSequenceNothingObserved()))
            return
        }
        let stream = Self.sequentialBoundStream(history)
        guard !stream.isEmpty else {
            trace.record(.confidenceSequence, .noOp(reason: Self.confidenceSequenceNoCastVerdicts(history)))
            return
        }
        recordConfidenceSequence(
            await Self.confidenceSequenceRead(
                stream,
                parameters: ConfidenceSequenceParameters(
                    alpha: alpha, referenceRate: referenceRate,
                    degradedRate: degradedRate, auditCeiling: auditCeiling
                )
            ),
            into: &trace
        )
    }

    private func recordConfidenceSequence(
        _ result: ConfidenceSequenceResult,
        into trace: inout PipelineTrace
    ) {
        switch result {
        case let .refused(message):
            trace.record(.confidenceSequence, .failed(message: message))
        case let .read(reading):
            trace.record(.confidenceSequence, .ran(detail: Self.confidenceSequenceDetail(reading)))
        }
    }

    // MARK: - reading the panel as one interval

    /// One reading: the interval that holds after the whole stream, what happened to the
    /// advertised rate along the way, and what the construction itself costs.
    ///
    /// `referenceRemainsAdmissible()` is not carried alongside `firstExclusionTrial`. The package
    /// defines the first as `firstExclusionTrial == nil`, so storing both would be two fields
    /// answering one question — the duplication this pipeline's siblings have deleted rather than
    /// tested. Not `Equatable`, for the same reason: nothing here calls `==`.
    struct ConfidenceSequenceReading: Sendable {
        let alpha: Double
        let referenceRate: Double
        let degradedRate: Double
        let interval: AnytimeInterval
        /// The 1-based trial the advertised rate left the interval at — `nil` while it holds.
        let firstExclusionTrial: Int?
        /// The horizon the exact audit was actually run to, which the ceiling may have capped.
        let auditedHorizon: Int
        /// `referenceRate` as the truth: the construction's realised miscoverage.
        let miscoverage: ExactExclusionProfile
        /// `degradedRate` as the truth: the chance those same looks catch the degradation.
        let detection: ExactExclusionProfile
        /// Expected width at the audited horizon when the rate really is the advertised one.
        let expectedWidth: Double
    }

    enum ConfidenceSequenceResult: Sendable {
        case read(ConfidenceSequenceReading)
        case refused(String)
    }

    /// The configuration one read is run against, bundled so the read stays under SwiftLint's
    /// parameter-count limit. The wrapper above still names each value separately, because that
    /// rule ignores parameters carrying a default.
    struct ConfidenceSequenceParameters: Sendable {
        let alpha: Double
        let referenceRate: Double
        let degradedRate: Double
        let auditCeiling: Int
    }

    /// Replays the stream through the mixture martingale and audits the construction that did it.
    ///
    /// One `do`/`catch` around the whole reading rather than one per call. Every throw here is
    /// the same kind of thing — a rate or a horizon this app asked for that the construction
    /// cannot honour — and splitting them would produce arms distinguished only by which
    /// validator fired, which is a distinction no reader of the trace can act on.
    static func confidenceSequenceRead(
        _ stream: [Bool],
        parameters: ConfidenceSequenceParameters
    ) async -> ConfidenceSequenceResult {
        do {
            let sequence = try MixtureConfidenceSequence(alpha: parameters.alpha)
            let monitor = try ConfidenceSequenceMonitor(
                sequence: sequence, referenceRate: parameters.referenceRate
            )
            let interval = try await monitor.observe(contentsOf: stream)
            let horizon = min(stream.count, parameters.auditCeiling)
            let solver = ExclusionSolver(sequence: sequence)
            return .read(
                ConfidenceSequenceReading(
                    alpha: parameters.alpha,
                    referenceRate: parameters.referenceRate,
                    degradedRate: parameters.degradedRate,
                    interval: interval,
                    firstExclusionTrial: await monitor.firstExclusionTrial,
                    auditedHorizon: horizon,
                    miscoverage: try solver.profile(
                        referenceRate: parameters.referenceRate,
                        trueRate: parameters.referenceRate,
                        horizon: horizon
                    ),
                    detection: try solver.profile(
                        referenceRate: parameters.referenceRate,
                        trueRate: parameters.degradedRate,
                        horizon: horizon
                    ),
                    expectedWidth: try solver.expectedIntervalWidth(
                        trials: horizon, trueRate: parameters.referenceRate
                    )
                )
            )
        } catch {
            return .refused(Self.confidenceSequenceDeclined(parameters: parameters, error: error))
        }
    }

    // MARK: - the outcomes

    private static func confidenceSequenceNothingObserved() -> String {
        "no turn observed yet; an interval for the gate pass rate still needs turns, and this "
            + "panel has produced none"
    }

    private static func confidenceSequenceNoCastVerdicts(_ history: ObservationHistory) -> String {
        "\(history.count) observed turn(s), but every gate abstained on every one of them; an "
            + "abstention is not a trial, so there is no rate to put an interval around"
    }

    private static func confidenceSequenceDeclined(
        parameters: ConfidenceSequenceParameters, error: Error
    ) -> String {
        "a confidence sequence at alpha=\(confidenceSequenceFormat(parameters.alpha, 2)) watching "
            + "an advertised rate of \(confidenceSequenceFormat(parameters.referenceRate, 2)) "
            + "against \(confidenceSequenceFormat(parameters.degradedRate, 2)), audited to at most "
            + "\(parameters.auditCeiling) trial(s), was declined — \(error); no interval was "
            + "published under a configuration the construction did not accept"
    }

    // MARK: - the detail

    private static func confidenceSequenceDetail(_ reading: ConfidenceSequenceReading) -> String {
        [
            confidenceSequenceValueLine(reading),
            confidenceSequenceReferenceLine(reading),
            confidenceSequenceMiscoverageLine(reading),
            confidenceSequenceDetectionLine(reading)
        ].joined(separator: "; ")
    }

    private static func confidenceSequenceValueLine(_ reading: ConfidenceSequenceReading) -> String {
        "\(reading.interval.successes) of \(reading.interval.trials) cast verdict(s) affirmed "
            + "leaves the gate pass rate in ["
            + "\(confidenceSequenceFormat(reading.interval.lowerBound)), "
            + "\(confidenceSequenceFormat(reading.interval.upperBound))], a width of "
            + "\(confidenceSequenceFormat(reading.interval.width)), at a total miscoverage budget "
            + "of \(confidenceSequenceFormat(reading.alpha, 2)) spent once across every look"
    }

    private static func confidenceSequenceReferenceLine(_ reading: ConfidenceSequenceReading) -> String {
        let advertised = confidenceSequenceFormat(reading.referenceRate, 2)
        guard let trial = reading.firstExclusionTrial else {
            return "the advertised rate of \(advertised) is still admissible after "
                + "\(reading.interval.trials) look(s)"
        }
        return "the advertised rate of \(advertised) stopped being admissible at trial \(trial) of "
            + "\(reading.interval.trials)"
    }

    private static func confidenceSequenceMiscoverageLine(_ reading: ConfidenceSequenceReading) -> String {
        "by enumeration at a horizon of \(reading.auditedHorizon) trial(s) against "
            + "\(reading.interval.trials) actually taken, this construction's exact "
            + "\(confidenceSequenceLabel(reading.miscoverage)) is "
            + "\(confidenceSequenceFormat(reading.miscoverage.exclusionProbability)) against a "
            + "budget of \(confidenceSequenceFormat(reading.alpha, 2)), and its expected interval "
            + "width there is \(confidenceSequenceFormat(reading.expectedWidth))"
    }

    private static func confidenceSequenceDetectionLine(_ reading: ConfidenceSequenceReading) -> String {
        "the same enumeration against a true rate of "
            + "\(confidenceSequenceFormat(reading.degradedRate, 2)) reads as "
            + "\(confidenceSequenceLabel(reading.detection)) = "
            + "\(confidenceSequenceFormat(reading.detection.exclusionProbability)), "
            + "\(confidenceSequenceExpectedTrial(reading.detection))"
    }

    /// The same number means two different things depending on what the solver was handed, and
    /// the package says which: `measuresMiscoverage` is true exactly when the reference rate was
    /// also given as the truth. Naming it in the detail keeps a reader from reading a power
    /// figure as a coverage failure.
    static func confidenceSequenceLabel(_ profile: ExactExclusionProfile) -> String {
        profile.measuresMiscoverage ? "miscoverage" : "detection power"
    }

    private static func confidenceSequenceExpectedTrial(_ profile: ExactExclusionProfile) -> String {
        guard let trial = profile.expectedFirstExclusionTrial else {
            return "no path within that horizon reaches it, so there is no expected trial to quote"
        }
        return "first reached at trial \(confidenceSequenceFormat(trial, 2)) on average"
    }

    static func confidenceSequenceFormat(_ value: Double, _ places: Int = 6) -> String {
        String(format: "%.\(places)f", value)
    }
}
