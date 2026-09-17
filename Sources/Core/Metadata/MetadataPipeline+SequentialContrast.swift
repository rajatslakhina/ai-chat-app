import EffectiveVoteKit
import Foundation
import SequentialContrastKit

extension MetadataPipeline {
    /// Total miscoverage budget for the **whole sequence** of readings, and for both component
    /// sequences inside each one.
    ///
    /// The same 0.05 its two neighbours spend, deliberately. All three read the same panel, and a
    /// different budget here would turn a comparison of three methods into a comparison of three
    /// configurations.
    static let sequentialContrastAlpha = 0.05

    /// The difference the interval is asked about.
    ///
    /// Zero, and nothing else is worth asking first. Two gates that admit at genuinely different
    /// rates are two gates doing different jobs; two that do not are a candidate for being one
    /// gate, which is a finding this app has no other way to reach.
    static let sequentialContrastReferenceDifference = 0.0

    /// The longest horizon the exact audit is run to.
    ///
    /// `ContrastExclusionSolver` walks an `O(horizon^3)` lattice, so auditing at the observed
    /// horizon alone would make a background task's cost grow cubically with session length. The
    /// detail always names the horizon actually audited alongside the turns actually paired, so a
    /// capped audit is never reported as an uncapped one.
    ///
    /// Lower than `confidenceSequence`'s 60 on purpose: that stage's lattice is `O(horizon^2)` and
    /// this one's is a full dimension worse, so the same budget buys a shorter horizon. Saying so
    /// here is cheaper than rediscovering it from a profiler.
    static let sequentialContrastAuditCeiling = 30

    /// Publishes a time-uniform interval for the **difference** between two gates' admit rates.
    func auditSequentialContrast(
        trace: inout PipelineTrace,
        store: PanelHistoryStore = .shared
    ) async {
        await auditSequentialContrast(trace: &trace, history: await store.history)
    }

    /// The same audit over a supplied history.
    ///
    /// Every stage before this one pooled the panel into a single stream and asked about one
    /// rate. That pooling is exactly what makes the question here unanswerable: it throws away
    /// which gate cast which verdict on which turn, and a comparison between two gates is a
    /// statement about precisely that. This stage re-reads the panel *paired* instead — same
    /// verdicts, same turns, kept side by side.
    func auditSequentialContrast(
        trace: inout PipelineTrace,
        history: ObservationHistory,
        alpha: Double = MetadataPipeline.sequentialContrastAlpha,
        referenceDifference: Double = MetadataPipeline.sequentialContrastReferenceDifference,
        auditCeiling: Int = MetadataPipeline.sequentialContrastAuditCeiling
    ) async {
        guard !history.observations.isEmpty else {
            trace.record(.sequentialContrast, .skipped(reason: Self.sequentialContrastNothingObserved()))
            return
        }
        guard let pairing = Self.sequentialContrastPairing(history) else {
            trace.record(.sequentialContrast, .noOp(reason: Self.sequentialContrastNoPair(history)))
            return
        }
        recordSequentialContrast(
            await Self.sequentialContrastRead(
                pairing,
                parameters: SequentialContrastParameters(
                    alpha: alpha,
                    referenceDifference: referenceDifference,
                    auditCeiling: auditCeiling
                )
            ),
            into: &trace
        )
    }

    private func recordSequentialContrast(
        _ result: SequentialContrastResult,
        into trace: inout PipelineTrace
    ) {
        switch result {
        case let .refused(message):
            trace.record(.sequentialContrast, .failed(message: message))
        case let .read(reading):
            trace.record(.sequentialContrast, .ran(detail: Self.sequentialContrastDetail(reading)))
        }
    }

    // MARK: - pairing the panel instead of pooling it

    /// Two named gates and the turns on which both of them cast a verdict.
    struct SequentialContrastPairing: Sendable {
        let judgeA: String
        let judgeB: String
        /// Turns where both cast, oldest first.
        let stream: [PairedOutcome]
        /// Turns where at least one of the two abstained, and which therefore carry no paired
        /// comparison at all.
        let unpairedTurns: Int
    }

    /// The first two judges in `history.judges`' sorted order, and every turn both ruled on.
    ///
    /// Sorted order rather than "the two that cast most", because the roster is fixed by this
    /// app's gate set and a selection rule that depends on the data would make the stage compare
    /// different gates on different days without saying so. Returns `nil` when there are fewer
    /// than two judges or no turn they both ruled on — both of which are "nothing to compare"
    /// rather than a failure.
    ///
    /// A turn where one gate abstained is dropped, not counted as agreement. An abstention is not
    /// a verdict, and pairing it against a cast one would manufacture a disagreement that nobody
    /// expressed. Those turns are counted and reported instead, because how many of them there
    /// are is the honest measure of how much of the panel this stage could not use.
    static func sequentialContrastPairing(_ history: ObservationHistory) -> SequentialContrastPairing? {
        let judges = history.judges
        guard judges.count >= 2 else { return nil }
        let judgeA = judges[0]
        let judgeB = judges[1]
        var stream: [PairedOutcome] = []
        var unpaired = 0
        for observation in history.observations {
            guard let left = observation.verdicts[judgeA], left.isCast,
                  let right = observation.verdicts[judgeB], right.isCast else {
                unpaired += 1
                continue
            }
            stream.append(PairedOutcome(systemA: left == .affirm, systemB: right == .affirm))
        }
        guard !stream.isEmpty else { return nil }
        return SequentialContrastPairing(
            judgeA: judgeA.rawValue,
            judgeB: judgeB.rawValue,
            stream: stream,
            unpairedTurns: unpaired
        )
    }

    /// One reading: what the paired construction says, what the same data says with the pairing
    /// discarded, and what the construction itself costs.
    ///
    /// `referenceRemainsAdmissible()` is not stored beside `firstExclusionTrial` for the reason
    /// its neighbour gives: the package defines one as the other being `nil`, and two fields
    /// answering one question is the duplication this pipeline deletes rather than tests.
    struct SequentialContrastReading: Sendable {
        let alpha: Double
        let referenceDifference: Double
        let judgeA: String
        let judgeB: String
        let tally: ContrastTally
        /// The fraction of paired turns the two gates agreed on.
        ///
        /// Carried as a plain `Double` rather than read back off `tally` at the point of use.
        /// `ContrastTally.agreementRate` is optional because a tally of nothing has no rate, and
        /// defaulting that away at the call site would be a branch no test could take — the
        /// tenth appearance of the unreachable-default defect this repo's README tracks. It is
        /// unwrapped once, below, where an empty stream is a real outcome that gets reported.
        let agreementRate: Double
        let unpairedTurns: Int
        /// The interval that uses the pairing.
        let paired: ContrastInterval
        /// The interval the identical data supports once the pairing is thrown away.
        let unpaired: ContrastInterval
        /// The 1-based turn the reference difference left the paired interval at — `nil` while it
        /// holds.
        let firstExclusionTrial: Int?
        /// The horizon the exact audit was actually run to, which the ceiling may have capped.
        let auditedHorizon: Int
        /// The true difference as the reference: the construction's realised miscoverage.
        let miscoverage: ExactContrastProfile
        /// Zero as the reference: the chance these looks catch that the gates differ at all.
        let pairedDetection: ExactContrastProfile
        /// The same question asked of the construction that discards the pairing.
        let unpairedDetection: ExactContrastProfile
        /// Expected widths at the audited horizon, both constructions.
        let widths: WidthComparison
    }

    enum SequentialContrastResult: Sendable {
        case read(SequentialContrastReading)
        case refused(String)
    }

    /// The configuration one read is run against, bundled so the read stays under SwiftLint's
    /// parameter-count limit.
    struct SequentialContrastParameters: Sendable {
        let alpha: Double
        let referenceDifference: Double
        let auditCeiling: Int
    }

    /// Replays the paired panel through both constructions and audits what each one did.
    ///
    /// One `do`/`catch` around the whole reading, for the reason its neighbour gives: every throw
    /// here is the same kind of thing — a difference or a horizon this app asked for that the
    /// construction cannot honour — and arms distinguished only by which validator fired are a
    /// distinction no reader of the trace can act on.
    static func sequentialContrastRead(
        _ pairing: SequentialContrastPairing,
        parameters: SequentialContrastParameters
    ) async -> SequentialContrastResult {
        do {
            let monitor = try ContrastMonitor(
                alpha: parameters.alpha, referenceDifference: parameters.referenceDifference
            )
            let paired = try await monitor.observe(contentsOf: pairing.stream)
            let tally = await monitor.tally
            guard let agreementRate = tally.agreementRate else {
                return .refused(Self.sequentialContrastEmptyStream(pairing: pairing))
            }
            let horizon = min(pairing.stream.count, parameters.auditCeiling)
            let solver = try ContrastExclusionSolver(alpha: parameters.alpha)
            let joint = try Self.sequentialContrastJoint(tally)
            return .read(
                SequentialContrastReading(
                    alpha: parameters.alpha,
                    referenceDifference: parameters.referenceDifference,
                    judgeA: pairing.judgeA,
                    judgeB: pairing.judgeB,
                    tally: tally,
                    agreementRate: agreementRate,
                    unpairedTurns: pairing.unpairedTurns,
                    paired: paired,
                    unpaired: try await monitor.unpairedInterval(),
                    firstExclusionTrial: await monitor.firstExclusionTrial,
                    auditedHorizon: horizon,
                    miscoverage: try solver.pairedProfile(
                        referenceDifference: joint.difference, joint: joint, horizon: horizon
                    ),
                    pairedDetection: try solver.pairedProfile(
                        referenceDifference: parameters.referenceDifference,
                        joint: joint, horizon: horizon
                    ),
                    unpairedDetection: try solver.unpairedProfile(
                        referenceDifference: parameters.referenceDifference,
                        joint: joint, horizon: horizon
                    ),
                    widths: try solver.widthComparison(trials: horizon, joint: joint)
                )
            )
        } catch {
            return .refused(Self.sequentialContrastDeclined(pairing: pairing, error: error))
        }
    }

    /// The joint the observed panel implies, which is the distribution the exact solver walks.
    ///
    /// Derived from the tally rather than assumed, so the audit prices *this* session's panel and
    /// not a textbook one.
    static func sequentialContrastJoint(_ tally: ContrastTally) throws -> PairedJointDistribution {
        let total = Double(tally.trials)
        return try PairedJointDistribution(
            bothSucceed: Double(tally.bothSucceeded) / total,
            onlyASucceeds: Double(tally.onlyASucceeded) / total,
            onlyBSucceeds: Double(tally.onlyBSucceeded) / total
        )
    }

    // MARK: - the outcomes

    private static func sequentialContrastNothingObserved() -> String {
        "no turn observed yet; comparing two gates' admit rates needs turns they have both ruled "
            + "on, and this panel has produced none"
    }

    private static func sequentialContrastNoPair(_ history: ObservationHistory) -> String {
        "\(history.count) observed turn(s), but no turn has two gates casting a verdict together; "
            + "an abstention is not a verdict, so pairing one against a cast verdict would invent "
            + "a disagreement nobody expressed, and there is no difference to put an interval around"
    }

    /// A pairing carrying no turns at all, which the audit path cannot produce but a direct
    /// caller can. Reported rather than defaulted away: a rate over nothing is not zero, it is
    /// absent, and saying "they agreed 0.000000 of the time" would be a lie with a number on it.
    private static func sequentialContrastEmptyStream(pairing: SequentialContrastPairing) -> String {
        "a contrast between \(pairing.judgeA) and \(pairing.judgeB) was asked for over zero "
            + "paired turn(s); an agreement rate over no turns is absent rather than zero, so no "
            + "interval was published"
    }

    private static func sequentialContrastDeclined(
        pairing: SequentialContrastPairing, error: Error
    ) -> String {
        "a contrast sequence at alpha=\(sequentialContrastFormat(sequentialContrastAlpha, 2)) "
            + "comparing \(pairing.judgeA) against \(pairing.judgeB) over "
            + "\(pairing.stream.count) paired turn(s) was declined — \(error); no interval was "
            + "published under a configuration the construction did not accept"
    }

    // MARK: - the detail

    private static func sequentialContrastDetail(_ reading: SequentialContrastReading) -> String {
        [
            sequentialContrastValueLine(reading),
            sequentialContrastOverlapLine(reading),
            sequentialContrastReferenceLine(reading),
            sequentialContrastAuditLine(reading)
        ].joined(separator: "; ")
    }

    private static func sequentialContrastValueLine(_ reading: SequentialContrastReading) -> String {
        "\(reading.judgeA) against \(reading.judgeB) over \(reading.tally.trials) turn(s) both "
            + "ruled on (\(reading.unpairedTurns) turn(s) had no paired verdict and were dropped) "
            + "leaves the difference in admit rates at ["
            + "\(sequentialContrastSigned(reading.paired.lowerBound)), "
            + "\(sequentialContrastSigned(reading.paired.upperBound))], a width of "
            + "\(sequentialContrastFormat(reading.paired.width)), at a total miscoverage budget of "
            + "\(sequentialContrastFormat(reading.alpha, 2)) spent once across every look"
    }

    /// The line that exists because the mistake it guards against is the common one: two gates
    /// whose own rate intervals overlap are routinely called indistinguishable, and that does not
    /// follow.
    private static func sequentialContrastOverlapLine(_ reading: SequentialContrastReading) -> String {
        "they agreed on \(reading.tally.concordantTrials) and disagreed on "
            + "\(reading.tally.discordantTrials) of those turns, an agreement rate of "
            + "\(sequentialContrastFormat(reading.agreementRate)); discarding that "
            + "pairing widens the same reading to ["
            + "\(sequentialContrastSigned(reading.unpaired.lowerBound)), "
            + "\(sequentialContrastSigned(reading.unpaired.upperBound))], which is "
            + "\(sequentialContrastFormat(reading.unpaired.width / reading.paired.width, 4))x wider"
    }

    private static func sequentialContrastReferenceLine(_ reading: SequentialContrastReading) -> String {
        let reference = sequentialContrastSigned(reading.referenceDifference)
        guard let trial = reading.firstExclusionTrial else {
            return "a difference of \(reference) — the two gates admitting at the same rate — is "
                + "still admissible after \(reading.tally.trials) look(s)"
        }
        return "a difference of \(reference) stopped being admissible at turn \(trial) of "
            + "\(reading.tally.trials), and no correction is owed for the looks before it"
    }

    /// Both readings of the same enumeration, labelled from the profile's own flag rather than
    /// from what this call site passed, so a power figure can never be read as a coverage failure.
    private static func sequentialContrastAuditLine(_ reading: SequentialContrastReading) -> String {
        "by enumeration at a horizon of \(reading.auditedHorizon) turn(s) against "
            + "\(reading.tally.trials) actually paired, this construction's exact "
            + "\(sequentialContrastLabel(reading.miscoverage)) is "
            + "\(sequentialContrastFormat(reading.miscoverage.exclusionProbability)) against a "
            + "budget of \(sequentialContrastFormat(reading.alpha, 2)), its "
            + "\(sequentialContrastLabel(reading.pairedDetection)) against the same horizon is "
            + "\(sequentialContrastFormat(reading.pairedDetection.exclusionProbability)) where the "
            + "unpaired construction reads "
            + "\(sequentialContrastFormat(reading.unpairedDetection.exclusionProbability)), and the "
            + "expected widths there are \(sequentialContrastFormat(reading.widths.pairedWidth)) "
            + "paired against \(sequentialContrastFormat(reading.widths.unpairedWidth)) unpaired, a "
            + "gain of \(sequentialContrastFormat(reading.widths.pairingGain, 4))x"
    }

    /// The same number means two different things depending on what the solver was handed, and
    /// the package says which.
    static func sequentialContrastLabel(_ profile: ExactContrastProfile) -> String {
        profile.measuresMiscoverage ? "miscoverage" : "detection power"
    }

    static func sequentialContrastFormat(_ value: Double, _ places: Int = 6) -> String {
        String(format: "%.\(places)f", value)
    }

    static func sequentialContrastSigned(_ value: Double, _ places: Int = 6) -> String {
        String(format: "%+.\(places)f", value)
    }
}
