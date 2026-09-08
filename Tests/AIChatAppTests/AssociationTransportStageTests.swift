import AssociationTransportKit
import EffectiveVoteKit
import EvalHarness
import Foundation
import Testing
@testable import AIChatApp

/// The `associationTransport` stage, which reads the structure `associationFit` designs.
///
/// That stage fits a control structure onto the gates' verdict **margins**. This one builds the
/// **joint** table those margins are a projection of — the thing an association actually lives in
/// and the thing nothing else in this app constructs — and reports two things a designed
/// structure cannot have: what an empty cell was decided to mean, and how much of the result the
/// panel is large enough to distinguish from independence.
@Suite("Association transport stage")
struct AssociationTransportStageTests {
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
        trace.records.first { $0.stage == .associationTransport }?.outcome
    }

    /// Two gates with different rates and all three verdicts in play.
    private func threeWayHistory(count: Int = 30) -> ObservationHistory {
        ObservationHistory((0..<count).map { index in
            PanelObservation(
                id: "turn-\(index)",
                verdicts: [
                    Self.answerability: index % 3 == 0 ? .deny : .affirm,
                    Self.stability: index % 5 == 0 ? .abstain : (index % 4 == 0 ? .deny : .affirm)
                ],
                truth: nil
            )
        })
    }

    /// Two gates that voted identically, so the pair carries no rates to tell apart.
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

    /// A pair whose joint table fills every cell, so nothing has to be decided or invented.
    ///
    /// Built cell by cell rather than from an index formula, because "every cell is occupied" is
    /// the property under test and a formula that happens to miss one makes the test pass for the
    /// wrong reason. The margins are `[10, 11, 12]` against `[12, 11, 10]`, deliberately unequal
    /// so the pair is not skipped as two spellings of one gate.
    private func fullHistory() -> ObservationHistory {
        let cells = [[5, 3, 2], [4, 6, 1], [3, 2, 7]]
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

    @Test("a fresh install is quiet, and says why rather than reporting nothing")
    func skippedOnFreshInstall() async {
        var trace = PipelineTrace()
        await pipeline().auditAssociationTransport(trace: &trace, history: ObservationHistory([]))
        guard case let .skipped(reason) = outcome(trace) else {
            Issue.record("expected .skipped, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(reason.contains("no pair has fallen yet"))
    }

    @Test("one gate is not a pair")
    func noOpOnASingleGate() async {
        var trace = PipelineTrace()
        let history = ObservationHistory([
            PanelObservation(id: "t0", verdicts: [Self.answerability: .affirm], truth: nil),
            PanelObservation(id: "t1", verdicts: [Self.answerability: .deny], truth: nil)
        ])
        await pipeline().auditAssociationTransport(trace: &trace, history: history)
        guard case let .noOp(reason) = outcome(trace) else {
            Issue.record("expected .noOp, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(reason.contains("there is no pair"))
    }

    @Test("two gates that voted identically are one gate for this purpose")
    func noOpOnIdenticalGates() async {
        var trace = PipelineTrace()
        await pipeline().auditAssociationTransport(trace: &trace, history: identicalHistory())
        guard case let .noOp(reason) = outcome(trace) else {
            Issue.record("expected .noOp, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(reason.contains("two gates with identical margins are one gate"))
    }

    @Test("a panel with empty cells is read, and the decision behind reading it is reported")
    func ranOnAPanelWithEmptyCells() async {
        var trace = PipelineTrace()
        await pipeline().auditAssociationTransport(trace: &trace, history: threeWayHistory())
        guard case let .ran(detail) = outcome(trace) else {
            Issue.record("expected .ran, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(detail.contains("the joint table nothing else here builds"))
        #expect(detail.contains("read without deciding what an absence means it refuses"))
        #expect(detail.contains("exist only because"))
        #expect(detail.contains("clear independence at 95%"))
        #expect(detail.contains("away from independence"))
    }

    @Test("a panel with no empty cell needs no decision, and the stage says so")
    func ranOnAFullPanel() async {
        var trace = PipelineTrace()
        await pipeline().auditAssociationTransport(trace: &trace, history: fullHistory())
        guard case let .ran(detail) = outcome(trace) else {
            Issue.record("expected .ran, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(detail.contains("no cell is empty"))
        #expect(detail.contains("clear independence at 95%"))
    }

    /// The seam, and it is the policy input rather than a hook.
    @Test("a correction amount that is not positive is a stage failure")
    func failedOnAnImpossibleCorrection() async {
        var trace = PipelineTrace()
        await pipeline().auditAssociationTransport(
            trace: &trace, history: threeWayHistory(), policy: .corrected(by: 0)
        )
        guard case let .failed(message) = outcome(trace) else {
            Issue.record("expected .failed, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(message.contains("could not be read even with a correction"))
        #expect(message.contains("correctionNotPositive"))
    }

    /// The joint table is not the margins, which is the whole reason this stage exists.
    @Test("the pair is chosen on its joint table, and the margins are a projection of it")
    func jointTableIsNotTheMargins() throws {
        let history = threeWayHistory()
        let joint = try #require(
            MetadataPipeline.transportJoint(history, judges: history.judges)
        )
        #expect(joint.panel.itemCount == history.count)
        #expect(joint.panel.categoryCount == Verdict.allCases.count)
        // The diagonal of the joint table is exactly the turns the two gates agreed on, which no
        // pair of margins determines.
        let trace = (0..<joint.panel.categoryCount).reduce(0) { $0 + joint.panel.counts[$1][$1] }
        #expect(trace == joint.agreedTurns)
    }

    /// A fully crossed corpus makes every ratio exactly one, and no sample size separates that.
    ///
    /// Read as rules rather than absences, so nothing is added to any cell — adding a constant to
    /// unequal cells breaks exact independence, and this test is about the case where it holds.
    @Test("nothing is invented, and a ratio of exactly one needs no items because there is nothing to find")
    func nothingToDetect() async throws {
        var trace = PipelineTrace()
        await pipeline().auditAssociationTransport(
            trace: &trace, history: crossedHistory(), policy: .structural
        )
        guard case let .ran(detail) = outcome(trace) else {
            Issue.record("expected .ran, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(detail.contains("nothing was invented to reach that"))
        #expect(detail.contains("no covered block could be separated at any sample size"))
        #expect(!detail.contains("the correction moved the comparable ratios"))

        let panel = try ObservedPanel(counts: [[36, 36], [12, 12]])
        let structure = try StructureMeasurement.measure(panel)
        #expect(MetadataPipeline.transportCheapestClaim(structure) == nil)
    }

    /// A fully crossed pair: every joint count is exactly `a_i * b_j / n`, so every local odds
    /// ratio is exactly one and the margins still differ.
    private func crossedHistory() -> ObservationHistory {
        let cells = [[6, 6, 12], [3, 3, 6], [3, 3, 6]]
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

    @Test("the stage table names the package that owns it")
    func stageBelongsToItsPackage() {
        #expect(PipelineStage.associationTransport.package == "AssociationTransportKit")
        #expect(PipelineStage.associationTransport.title == "Association transport")
    }
}
