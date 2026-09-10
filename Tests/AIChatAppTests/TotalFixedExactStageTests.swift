import AssociationTransportKit
import ConditioningCostKit
import EffectiveVoteKit
import EvalHarness
import ExactAssociationKit
import Foundation
import Testing
import TotalFixedExactKit
@testable import AIChatApp

/// The `totalFixedExact` stage, which admits the nuisance parameter `unconditionalExact` left out.
///
/// Barnard's test keeps the one parameter a row-fixed design leaves. A panel of turns
/// cross-classified by two gates fixes neither margin, so its null leaves two and the honest
/// supremum is over a square. This stage takes that supremum, reports it beside the two cheaper
/// readings, and measures which way the cheapest one is wrong on the block it actually has.
@Suite("Total-fixed exact stage")
struct TotalFixedExactStageTests {
    private static let answerability = JudgeIdentity("answerability")
    private static let stability = JudgeIdentity("verdict stability")

    private func pipeline() async -> MetadataPipeline {
        MetadataPipeline(
            completer: ScriptedCompleter(
                title: [MetadataHarness.goodTitle],
                followUps: [MetadataHarness.goodFollowUps]
            ),
            contracts: await Composition.makeContracts(),
            transcripts: InMemoryTranscriptStore()
        )
    }

    private func outcome(_ trace: PipelineTrace) -> StageOutcome? {
        trace.records.first { $0.stage == .totalFixedExact }?.outcome
    }

    /// Builds a history whose joint table is exactly `cells`.
    ///
    /// The fixture has to satisfy the selector that finds the block, not only the arithmetic of
    /// the block. `transportJoint` refuses a pair whose gates have the same marginal verdict
    /// rates, and for a block in the top-left corner those margins coincide exactly when `b == c`
    /// — so a symmetric block never reaches this stage at all.
    private func history(cells: [[Int]]) -> ObservationHistory {
        let verdicts = Verdict.allCases
        var observations: [PanelObservation] = []
        for (row, line) in cells.enumerated() {
            for (column, count) in line.enumerated() {
                for _ in 0..<count {
                    observations.append(
                        PanelObservation(
                            id: "turn-\(observations.count)",
                            verdicts: [
                                Self.answerability: verdicts[row],
                                Self.stability: verdicts[column]
                            ],
                            truth: nil
                        )
                    )
                }
            }
        }
        return ObservationHistory(observations)
    }

    /// A block of `6/8` against `1/6`: fourteen items, so its design is over the audit budget.
    private func wideBlockHistory() -> ObservationHistory {
        history(cells: [[6, 2, 1], [1, 5, 0], [0, 0, 0]])
    }

    /// A block of `9/10` against `3/10`: twenty items, where the row-fixed reading is the lower.
    private func lowerCheaperHistory() -> ObservationHistory {
        history(cells: [[9, 1, 1], [3, 7, 0], [0, 0, 0]])
    }

    /// A twelve-item block, small enough that its level can actually be audited.
    private func auditableHistory() -> ObservationHistory {
        history(cells: [[6, 2, 0], [1, 3, 0], [0, 0, 0]])
    }

    private func constantGateHistory() -> ObservationHistory {
        history(cells: [[5, 0, 0], [3, 0, 0], [2, 0, 0]])
    }

    private func identicalHistory(count: Int = 20) -> ObservationHistory {
        ObservationHistory((0..<count).map { index in
            let verdict: Verdict = index % 3 == 0 ? .deny : .affirm
            return PanelObservation(
                id: "turn-\(index)",
                verdicts: [Self.answerability: verdict, Self.stability: verdict],
                truth: nil
            )
        })
    }

    private func singleGateHistory() -> ObservationHistory {
        ObservationHistory((0..<6).map { index in
            PanelObservation(
                id: "turn-\(index)",
                verdicts: [Self.answerability: index % 2 == 0 ? .affirm : .deny],
                truth: nil
            )
        })
    }

    @Test("a fresh install is quiet, and says why rather than reporting nothing")
    func skippedOnFreshInstall() async {
        var trace = PipelineTrace()
        await pipeline().auditTotalFixedExact(trace: &trace, history: ObservationHistory([]))
        guard case .skipped(let reason)? = outcome(trace) else {
            Issue.record("expected a skip, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(reason.contains("no turn observed"))
    }

    @Test("a level that disagrees with exactAssociation's is refused rather than reported")
    func levelMismatchIsRefused() async {
        var trace = PipelineTrace()
        await pipeline().auditTotalFixedExact(
            trace: &trace,
            history: wideBlockHistory(),
            confidence: .ninetyNine
        )
        guard case .failed(let message)? = outcome(trace) else {
            Issue.record("expected a refusal, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(message.contains("99%"))
        #expect(message.contains("three decisions at one level"))
    }

    @Test("one gate is not a cross-classification, and the stage says which number is wrong")
    func oneGateIsNoOp() async {
        var trace = PipelineTrace()
        await pipeline().auditTotalFixedExact(trace: &trace, history: singleGateHistory())
        guard case .noOp(let reason)? = outcome(trace) else {
            Issue.record("expected a no-op, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(reason.contains("1 gate(s)"))
    }

    @Test("two gates that never differ have no block whose rows could differ")
    func identicalGatesAreNoOp() async {
        var trace = PipelineTrace()
        await pipeline().auditTotalFixedExact(trace: &trace, history: identicalHistory())
        guard case .noOp(let reason)? = outcome(trace) else {
            Issue.record("expected a no-op, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(reason.contains("different verdict rates"))
    }

    @Test("a joint table pinned by zero margins has nothing for any design to find")
    func pinnedBlockIsNoOp() async {
        var trace = PipelineTrace()
        await pipeline().auditTotalFixedExact(trace: &trace, history: constantGateHistory())
        guard case .noOp(let reason)? = outcome(trace) else {
            Issue.record("expected a no-op, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(reason.contains("pinned by a zero margin"))
    }

    @Test("a bracket that is not a positive width is refused, not quietly widened")
    func unusablePrecisionIsRefused() async {
        var trace = PipelineTrace()
        await pipeline().auditTotalFixedExact(
            trace: &trace,
            history: wideBlockHistory(),
            precision: 0
        )
        guard case .failed(let message)? = outcome(trace) else {
            Issue.record("expected a refusal, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(message.contains("declined"))
        #expect(message.contains("no smaller design was substituted"))
    }

    @Test("a block past what the package enumerates reaches the same refusal from the other side")
    func oversizedBlockIsRefused() throws {
        // 61 items in one block: CrossTable accepts it and TableSpace declines it, which is the
        // second of the two directions the single refusal arm has to be reachable from.
        let block = try ExactBlock(a: 31, b: 10, c: 10, d: 10)
        #expect(throws: Error.self) {
            _ = try MetadataPipeline.totalFixedTest(
                block,
                confidence: .ninetyFive,
                precision: 1e-7,
                budget: 500
            )
        }
        let readable = try ExactBlock(a: 6, b: 2, c: 1, d: 5)
        let fine = try MetadataPipeline.totalFixedTest(
            readable,
            confidence: .ninetyFive,
            precision: 1e-7,
            budget: 500
        )
        #expect(fine.itemCount == 14)
    }

    @Test("a real block is tested three ways, and the bracket it is known to is reported")
    func testsAllThreeDesigns() async throws {
        var trace = PipelineTrace()
        await pipeline().auditTotalFixedExact(trace: &trace, history: wideBlockHistory())
        guard case .ran(let detail)? = outcome(trace) else {
            Issue.record("expected a reading, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(detail.contains("total-fixed p ="))
        #expect(detail.contains("against row-fixed"))
        #expect(detail.contains("Fisher's"))
        #expect(detail.contains("bracket"))
        #expect(detail.contains("total fixed"))
        #expect(detail.contains("Both rates were estimated and neither was chosen"))
    }

    @Test("the direction the cheaper reading is wrong is measured on the block, not assumed")
    func directionIsMeasuredBothWays() throws {
        let higher = try MetadataPipeline.totalFixedTest(
            try ExactBlock(a: 9, b: 1, c: 3, d: 7),
            confidence: .ninetyFive,
            precision: 1e-7,
            budget: 500
        )
        // 20 items: the total-fixed reading is the larger, so the cheap one would over-reject
        #expect(higher.cheaperReadingIsLower)
        #expect(higher.rowFixed < higher.totalFixed)

        let lower = try MetadataPipeline.totalFixedTest(
            try ExactBlock(a: 10, b: 2, c: 3, d: 5),
            confidence: .ninetyFive,
            precision: 1e-7,
            budget: 500
        )
        // 20 items again, and the same comparison moves the other way
        #expect(lower.cheaperReadingIsLower == false)
        #expect(lower.rowFixed > lower.totalFixed)
    }

    @Test("both directions reach the detail line, not just the reading that produced them")
    func bothDirectionsAreRendered() async {
        var overRejecting = PipelineTrace()
        await pipeline().auditTotalFixedExact(
            trace: &overRejecting,
            history: lowerCheaperHistory()
        )
        guard case .ran(let lower)? = outcome(overRejecting) else {
            Issue.record("expected a reading, got \(String(describing: outcome(overRejecting)))")
            return
        }
        #expect(lower.contains("lower than the honest one"))
        #expect(lower.contains("would reject where"))

        var underPowered = PipelineTrace()
        await pipeline().auditTotalFixedExact(trace: &underPowered, history: wideBlockHistory())
        guard case .ran(let higher)? = outcome(underPowered) else {
            Issue.record("expected a reading, got \(String(describing: outcome(underPowered)))")
            return
        }
        #expect(higher.contains("higher than the honest one"))
        #expect(higher.contains("gives away power"))
        #expect(higher.contains("not a bound in either"))
    }

    @Test("a design over the audit budget is named with its table count, not swapped out")
    func unauditedDesignIsNamed() async {
        var trace = PipelineTrace()
        await pipeline().auditTotalFixedExact(trace: &trace, history: wideBlockHistory())
        guard case .ran(let detail)? = outcome(trace) else {
            Issue.record("expected a reading, got \(String(describing: outcome(trace)))")
            return
        }
        // 14 items admit C(17, 3) = 680 tables, over the budget of 500
        #expect(detail.contains("680 table(s)"))
        #expect(detail.contains("audit budget of 500"))
        #expect(detail.contains("was not measured here"))
    }

    @Test("a design inside the budget has its level audited for all four procedures")
    func auditedDesignReportsSpend() async {
        var trace = PipelineTrace()
        await pipeline().auditTotalFixedExact(trace: &trace, history: auditableHistory())
        guard case .ran(let detail)? = outcome(trace) else {
            Issue.record("expected a reading, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(detail.contains("the conditional test spends"))
        #expect(detail.contains("the row-fixed test"))
        #expect(detail.contains("asymptotic score test"))
        #expect(detail.contains("of the level it claims"))
    }

    @Test("the level audit ranks the procedures the way their designs predict")
    func spendRanking() throws {
        let size = try MetadataPipeline.totalFixedSize(12, alpha: 0.05)
        #expect(abs(size.conditionalSpend - 0.280356) < 1e-4)
        #expect(abs(size.totalFixedSpend - 0.993552) < 1e-4)
        #expect(size.asymptoticSpend > 1)
        #expect(size.asymptoticHolds == false)
        #expect(size.conditionalSpend < size.totalFixedSpend)
    }

    @Test("a budget of zero audits nothing and says so rather than comparing one thing to itself")
    func zeroBudgetSkipsTheAudit() throws {
        let reading = try MetadataPipeline.totalFixedTest(
            try ExactBlock(a: 6, b: 2, c: 1, d: 3),
            confidence: .ninetyFive,
            precision: 1e-7,
            budget: 0
        )
        #expect(reading.size == nil)
        #expect(reading.itemCount == 12)
    }

    @Test("the reading is reported as a bracket, and this design's is narrow")
    func bracketIsReported() throws {
        let reading = try MetadataPipeline.totalFixedTest(
            try ExactBlock(a: 6, b: 2, c: 1, d: 5),
            confidence: .ninetyFive,
            precision: 1e-7,
            budget: 500
        )
        #expect(reading.bracket >= 0)
        #expect(reading.bracket <= 1e-7)
        #expect(reading.designTables == 680)
        #expect(reading.admittedTables > 0)
        #expect(reading.admittedTables < reading.designTables)
        #expect(reading.worstRowRate >= 0)
        #expect(reading.worstColumnRate <= 1)
        #expect(reading.level == "95%")
    }

    @Test("numbers are formatted at the width they are asked for")
    func formatting() {
        #expect(MetadataPipeline.totalFixedFormat(0.0428) == "0.0428")
        #expect(MetadataPipeline.totalFixedFormat(0.0428, 2) == "0.04")
    }

    /// The stage table has to name every package in the series, and this one is the reminder.
    @Test("the new stage names its package and its title")
    func catalogued() {
        #expect(PipelineStage.totalFixedExact.package == "TotalFixedExactKit")
        #expect(PipelineStage.totalFixedExact.title == "Total-fixed exact")
    }
}
