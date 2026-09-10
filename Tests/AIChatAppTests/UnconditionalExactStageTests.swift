import AssociationTransportKit
import EffectiveVoteKit
import EvalHarness
import ExactAssociationKit
import Foundation
import Testing
import UnconditionalExactKit
@testable import AIChatApp

/// The `unconditionalExact` stage, which asks `exactAssociation`'s question without the assumption
/// `conditioningCost` priced.
///
/// Fisher's interval is exact because it conditions on all four margins, which removes the nuisance
/// parameter — free only when the design fixed them. Barnard's test keeps the parameter and
/// maximises over it. This stage runs both on the same block and reports where they disagree, and
/// it is explicit that the design it reads is not yet the design this panel has.
@Suite("Unconditional exact stage")
struct UnconditionalExactStageTests {
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
        trace.records.first { $0.stage == .unconditionalExact }?.outcome
    }

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

    @Test("a fresh install is quiet, and says why rather than reporting nothing")
    func skippedOnFreshInstall() async {
        var trace = PipelineTrace()
        await pipeline().auditUnconditionalExact(trace: &trace, history: ObservationHistory([]))
        guard case .skipped(let reason)? = outcome(trace) else {
            Issue.record("expected a skip, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(reason.contains("produced none"))
    }

    @Test("one gate is not two arms")
    func noOpOnASingleGate() async {
        var trace = PipelineTrace()
        let history = ObservationHistory([
            PanelObservation(id: "a", verdicts: [Self.answerability: .affirm], truth: nil),
            PanelObservation(id: "b", verdicts: [Self.answerability: .deny], truth: nil)
        ])
        await pipeline().auditUnconditionalExact(trace: &trace, history: history)
        guard case .noOp(let reason)? = outcome(trace) else {
            Issue.record("expected a no-op, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(reason.contains("only one thing here to be an arm"))
    }

    @Test("two gates that voted identically leave no block whose arms could differ")
    func noOpOnIdenticalGates() async {
        var trace = PipelineTrace()
        await pipeline().auditUnconditionalExact(trace: &trace, history: identicalHistory())
        guard case .noOp(let reason)? = outcome(trace) else {
            Issue.record("expected a no-op, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(reason.contains("no two gates have different verdict rates"))
    }

    @Test("a panel whose every block is pinned has no difference for any test to find")
    func noOpWhenEveryBlockIsPinned() async {
        var trace = PipelineTrace()
        await pipeline().auditUnconditionalExact(trace: &trace, history: constantGateHistory())
        guard case .noOp(let reason)? = outcome(trace) else {
            Issue.record("expected a no-op, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(reason.contains("both arms are constants"))
    }

    @Test("testing at a level exactAssociation does not draw at is refused, not reconciled")
    func failsOnALevelMismatch() async {
        var trace = PipelineTrace()
        await pipeline().auditUnconditionalExact(
            trace: &trace,
            history: history(cells: [[6, 2, 0], [1, 5, 0], [0, 0, 0]]),
            confidence: .ninetyNine
        )
        guard case .failed(let message)? = outcome(trace) else {
            Issue.record("expected a failure, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(message.contains("would not show up in the output"))
    }

    @Test("a small panel is tested both ways, and the level audit runs because it fits")
    func runsWithASizeAudit() async {
        var trace = PipelineTrace()
        await pipeline().auditUnconditionalExact(
            trace: &trace,
            history: history(cells: [[6, 2, 0], [1, 5, 0], [0, 0, 0]])
        )
        guard case .ran(let detail)? = outcome(trace) else {
            Issue.record("expected a run, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(detail.contains("unconditional p = "))
        #expect(detail.contains("against Fisher's"))
        #expect(detail.contains("% of the level it claims"))
        #expect(detail.contains("power that was paid for and never collected"))
        #expect(detail.contains("not yet a guarantee about the design this app has"))
    }

    @Test("a design too big to audit is named rather than swapped for a smaller one")
    func namesTheDesignItDidNotAudit() async {
        var trace = PipelineTrace()
        await pipeline().auditUnconditionalExact(
            trace: &trace,
            history: history(cells: [[6, 2, 0], [1, 5, 0], [0, 0, 0]]),
            budget: 4
        )
        guard case .ran(let detail)? = outcome(trace) else {
            Issue.record("expected a run, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(detail.contains("over this stage's audit budget of 4"))
        #expect(detail.contains("rather than measured on a smaller design"))
        #expect(detail.contains("unconditional p = "))
    }

    @Test("a bracket that is not a positive width is refused, because a bound needs one")
    func failsOnAnUnusablePrecision() async {
        var trace = PipelineTrace()
        await pipeline().auditUnconditionalExact(
            trace: &trace,
            history: history(cells: [[6, 2, 0], [1, 5, 0], [0, 0, 0]]),
            precision: 0
        )
        guard case .failed(let message)? = outcome(trace) else {
            Issue.record("expected a failure, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(message.contains("err towards rejecting"))
    }

    @Test("a block past what the package will enumerate is refused, not shrunk to fit")
    func failsOnADesignTooLarge() async {
        var trace = PipelineTrace()
        await pipeline().auditUnconditionalExact(
            trace: &trace,
            history: history(cells: [[260, 40, 0], [30, 170, 0], [0, 0, 0]])
        )
        guard case .failed(let message)? = outcome(trace) else {
            Issue.record("expected a failure, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(message.contains("no smaller design was substituted"))
    }

    @Test("the two tests disagree on a fifteen-turn panel, which is the stage's reason to exist")
    func reportsADisagreementThroughTheTrace() async {
        var trace = PipelineTrace()
        await pipeline().auditUnconditionalExact(
            trace: &trace,
            // A block is a two-by-two window, not a collapse: this one is 6/8 against 1/6.
            history: history(cells: [[6, 2, 1], [1, 5, 0], [0, 0, 0]])
        )
        guard case .ran(let detail)? = outcome(trace) else {
            Issue.record("expected a run, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(detail.contains("DISAGREE about whether there is anything here"))
    }

    @Test("the package's own reading of that block is what the stage prints")
    func reportsADisagreement() throws {
        let arms = try ArmCounts(successes: 6, trials: 8, otherSuccesses: 1, otherTrials: 6)
        let test = try UnconditionalExact(.remainder(MetadataPipeline.unconditionalExactPrecision))
        let free = try test.pValue(for: arms)
        let conditional = FisherConditional.pValue(for: arms)
        #expect(free.value < 0.05)
        #expect(conditional > 0.05)
        #expect(free.uncertainty < 1e-4)
    }

    @Test("the level audit measures what each test spends, and they are not the same")
    func measuresWhatEachTestSpends() throws {
        let arms = try ArmCounts(successes: 5, trials: 6, otherSuccesses: 1, otherTrials: 6)
        let reading = try MetadataPipeline.unconditionalSize(arms, alpha: 0.05)
        #expect(reading.conditionalSpend < 0.3)
        #expect(reading.unconditionalSpend > 0.6)
        #expect(reading.conditionalSize < reading.unconditionalSize)
    }

    @Test("the stage names its package and itself in the catalog")
    func catalogEntry() {
        #expect(PipelineStage.unconditionalExact.package == "UnconditionalExactKit")
        #expect(PipelineStage.unconditionalExact.title == "Unconditional exact")
    }
}
