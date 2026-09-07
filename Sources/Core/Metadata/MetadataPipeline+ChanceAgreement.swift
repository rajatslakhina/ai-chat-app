import ChanceAgreementKit
import EffectiveVoteKit
import Foundation

extension MetadataPipeline {
    /// The level every pair on this panel is judged at, matching its family-level siblings.
    static let chanceAlpha = comparisonAlpha

    /// Prices the chance term underneath every coefficient this app already publishes.
    func auditChanceAgreement(
        trace: inout PipelineTrace,
        store: PanelHistoryStore = .shared
    ) async {
        await auditChanceAgreement(trace: &trace, history: await store.history)
    }

    /// The same audit over a supplied history.
    ///
    /// `effectiveVote` publishes a coefficient for every pair of gates, `sampleWidth` prices its
    /// interval, `familyError` corrects the page for multiplicity and `effectiveComparison` fixes
    /// the denominator that correction divides by. Every one of those sits on a chance term that
    /// nobody in this app has ever named, and there is more than one candidate: Cohen holds each
    /// gate's own affirm-rate fixed, Scott treats the two gates as interchangeable, Bennett keeps
    /// neither rate. This stage names the one it spends and reports what the others would have
    /// said.
    func auditChanceAgreement(
        trace: inout PipelineTrace,
        history: ObservationHistory,
        level: Double = MetadataPipeline.chanceAlpha
    ) async {
        guard !history.observations.isEmpty else {
            trace.record(.chanceAgreement, .skipped(reason: Self.chanceNothingObserved()))
            return
        }
        let judges = history.judges
        guard judges.count >= 2 else {
            trace.record(.chanceAgreement, .noOp(reason: Self.chanceTooFewGates(judges.count)))
            return
        }
        let pairs = Self.chancePairs(from: history, judges: judges)
        guard !pairs.isEmpty else {
            trace.record(.chanceAgreement, .noOp(reason: Self.chanceNoPairBuilt(history)))
            return
        }
        let ledger = ChanceLedger(scheme: .itemPermutation)
        for (key, pair) in pairs { await ledger.record(key, pair: pair) }
        let tally = await Self.chanceTally(ledger, pairs: pairs, level: level)
        if let failure = tally.failure {
            trace.record(.chanceAgreement, .failed(message: failure))
            return
        }
        guard tally.priced > 0 else {
            trace.record(
                .chanceAgreement, .noOp(reason: Self.chanceNothingPriceable(tally, pairs.count))
            )
            return
        }
        trace.record(.chanceAgreement, .ran(detail: Self.chanceDetail(tally, history: history)))
    }

    // MARK: - building the pairs

    /// Every pair of gates, as the binary "did this gate affirm this turn" grid.
    ///
    /// The same basis `effectiveComparison` and `observedNull` measure on, and binary rather than
    /// three-way on purpose: `ParadoxDiagnostics` is defined by the two diagonals of a
    /// two-by-two table, so grading on affirm/not-affirm is what makes the prevalence question
    /// answerable here at all.
    static func chancePairs(
        from history: ObservationHistory, judges: [JudgeIdentity]
    ) -> [(String, LabelPair)] {
        var built: [(String, LabelPair)] = []
        for left in 0..<judges.count where left + 1 < judges.count {
            for right in (left + 1)..<judges.count {
                let first = Self.chanceGrades(history, judge: judges[left])
                let second = Self.chanceGrades(history, judge: judges[right])
                guard let pair = try? LabelPair(first: first, second: second, categoryCount: 2) else {
                    continue
                }
                built.append(("\(judges[left]) / \(judges[right])", pair))
            }
        }
        return built
    }

    private static func chanceGrades(_ history: ObservationHistory, judge: JudgeIdentity) -> [Int] {
        history.observations.map { $0.verdicts[judge] == .affirm ? 1 : 0 }
    }

    // MARK: - what the panel supports

    /// What every pair on the panel came to, counted rather than summarised.
    struct ChanceTally: Sendable, Equatable {
        var priced = 0
        var flat = 0
        var certain = 0
        var capped = 0
        var surviving = 0
        var strongest = 0.0
        var strongestKey = ""

        /// Set only when a pair failed for a reason that is not a property of the panel.
        ///
        /// A gate that never varied and a chance term of one are both facts about these gates,
        /// counted above and reported. Anything else means the stage was handed something it
        /// cannot work with — an out-of-range level, say — and that is the stage failing rather
        /// than the panel being quiet.
        var failure: String?
    }

    static func chanceTally(
        _ ledger: ChanceLedger, pairs: [(String, LabelPair)], level: Double
    ) async -> ChanceTally {
        var tally = ChanceTally()
        for (key, _) in pairs {
            do {
                let verdict = try await ledger.verdict(for: key, at: level)
                tally.priced += 1
                if verdict.survives { tally.surviving += 1 }
                if !verdict.ceiling.isUnrestricted { tally.capped += 1 }
                if verdict.reading.coefficient > tally.strongest {
                    tally.strongest = verdict.reading.coefficient
                    tally.strongestKey = key
                }
            } catch ChanceAgreementError.nullHasNoDispersion {
                tally.flat += 1
            } catch ChanceAgreementError.chanceAgreementIsCertain {
                tally.certain += 1
            } catch {
                tally.failure = tally.failure ?? "\(key): \(error)"
            }
        }
        return tally
    }

    // MARK: - the outcomes

    /// Quiet on a fresh install, and for a blunter reason than its sibling's.
    ///
    /// `observedNull` is quiet because the shape it would check is the assumption it exists to
    /// test. This one is quiet because a chance term is a statement about two gates' own rates,
    /// and a gate that has not graded anything has no rate.
    private static func chanceNothingObserved() -> String {
        "no turn observed yet; a chance term is a claim about how often each gate affirms, and "
            + "a gate that has graded nothing has no rate for the claim to be about"
    }

    private static func chanceTooFewGates(_ count: Int) -> String {
        "\(count) gate(s) on this panel; agreement is a property of a pair and there is no pair"
    }

    private static func chanceNoPairBuilt(_ history: ObservationHistory) -> String {
        "\(history.count) observed turn(s), but no pair of gates forms a panel of at least two "
            + "turns over at least two categories"
    }

    /// A panel where no pair admits a chance term at all, which is a finding rather than a gap.
    private static func chanceNothingPriceable(_ tally: ChanceTally, _ total: Int) -> String {
        "\(total) pair(s), none priceable: \(tally.flat) have a gate that affirmed every turn, so "
            + "permuting the other gate cannot move a count that never depended on its order, and "
            + "\(tally.certain) sit at a chance term of one; these gates agree because they always "
            + "affirm, which is the reading the coefficients above cannot distinguish from skill"
    }

    /// What the panel came to, with the ceiling the gates' own rates impose reported beside it.
    private static func chanceDetail(_ tally: ChanceTally, history: ObservationHistory) -> String {
        var parts = [
            "\(history.count) turn(s), \(tally.priced) pair(s) priced against an item-permutation "
                + "null (Cohen's chance term, which is that null's exact mean)",
            "\(tally.surviving) clear the level with the null's own dispersion attached, "
                + "which no coefficient in this app has ever carried"
        ]
        if tally.capped > 0 {
            parts.append(
                "\(tally.capped) pair(s) have gates whose affirm-rates differ, capping the "
                    + "coefficient below one before either gate has said anything; the shortfall "
                    + "against one there belongs to the panel, not to the gates"
            )
        } else {
            parts.append("every priced pair has matching affirm-rates, so a coefficient of one is reachable")
        }
        if tally.flat + tally.certain > 0 {
            parts.append(
                "\(tally.flat + tally.certain) pair(s) admit no chance term, having a gate that "
                    + "never varied"
            )
        }
        if !tally.strongestKey.isEmpty {
            parts.append("strongest \(tally.strongestKey) at " + format(tally.strongest))
        }
        return parts.joined(separator: "; ")
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}
