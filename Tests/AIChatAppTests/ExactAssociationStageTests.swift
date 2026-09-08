import AssociationTransportKit
import EffectiveVoteKit
import EvalHarness
import ExactAssociationKit
import Foundation
import Testing
@testable import AIChatApp

/// The `exactAssociation` stage, which audits the intervals `associationTransport` reports.
///
/// That stage draws a Woolf interval around every block of the joint table. Woolf's standard error
/// is a normal approximation on the log scale, valid in the limit of large counts, and this app's
/// panel is a few dozen turns with empty cells in it. This stage computes the interval that
/// approximation is approximating, and reports two things it cannot: which blocks were never
/// estimable at all, and which direction the approximation errs in.
@Suite("Exact association stage")
struct ExactAssociationStageTests {
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
        trace.records.first { $0.stage == .exactAssociation }?.outcome
    }

    /// Two gates with different rates, where one never abstains, so part of the table is empty.
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

    /// A pair whose joint table fills every cell, so both methods read every block.
    private func fullHistory() -> ObservationHistory {
        history(cells: [[5, 3, 2], [4, 6, 1], [3, 2, 7]])
    }

    /// A gate that has only ever said one thing, which pins every block of the joint table.
    ///
    /// Not a contrived shape. A gate that has not yet varied is the ordinary state of a fresh
    /// install after a handful of turns, and every block it takes part in has a margin of zero.
    private func constantGateHistory() -> ObservationHistory {
        history(cells: [[5, 0, 0], [3, 0, 0], [2, 0, 0]])
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

    @Test("a fresh install is quiet, and says why rather than reporting nothing")
    func skippedOnFreshInstall() async {
        var trace = PipelineTrace()
        await pipeline().auditExactAssociation(trace: &trace, history: ObservationHistory([]))
        guard case let .skipped(reason) = outcome(trace) else {
            Issue.record("expected .skipped, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(reason.contains("this one has seen nothing"))
    }

    @Test("one gate is not a pair")
    func noOpOnASingleGate() async {
        var trace = PipelineTrace()
        let history = ObservationHistory([
            PanelObservation(id: "t0", verdicts: [Self.answerability: .affirm], truth: nil),
            PanelObservation(id: "t1", verdicts: [Self.answerability: .deny], truth: nil)
        ])
        await pipeline().auditExactAssociation(trace: &trace, history: history)
        guard case let .noOp(reason) = outcome(trace) else {
            Issue.record("expected .noOp, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(reason.contains("there is no pair"))
    }

    @Test("two gates that voted identically leave no joint table to estimate")
    func noOpOnIdenticalGates() async {
        var trace = PipelineTrace()
        await pipeline().auditExactAssociation(trace: &trace, history: identicalHistory())
        guard case let .noOp(reason) = outcome(trace) else {
            Issue.record("expected .noOp, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(reason.contains("no joint table here whose blocks could be estimated"))
    }

    /// The outcome the asymptotic side cannot reach: a panel where every interval would be fiction.
    @Test("a gate that has only said one thing pins every block, and an interval for one would be fiction")
    func noOpWhenEveryBlockIsPinned() async {
        var trace = PipelineTrace()
        await pipeline().auditExactAssociation(trace: &trace, history: constantGateHistory())
        guard case let .noOp(reason) = outcome(trace) else {
            Issue.record("expected .noOp, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(reason.contains("have a margin of zero"))
        #expect(reason.contains("fiction rather than an approximation"))
    }

    @Test("a partly empty table is audited, and the pinned blocks are named as unestimable")
    func ranOnAPanelWithPinnedBlocks() async {
        var trace = PipelineTrace()
        await pipeline().auditExactAssociation(trace: &trace, history: threeWayHistory())
        guard case let .ran(detail) = outcome(trace) else {
            Issue.record("expected .ran, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(detail.contains("pinned by a zero margin"))
        #expect(detail.contains("added to cells nobody landed in"))
        #expect(detail.contains("clear independence exactly at 95%"))
        #expect(detail.contains("Fisher two-sided p"))
        #expect(detail.contains("wider than the mid-p one"))
    }

    @Test("a full table pins nothing, and both methods read every block from the same integers")
    func ranOnAFullPanel() async {
        var trace = PipelineTrace()
        await pipeline().auditExactAssociation(trace: &trace, history: fullHistory())
        guard case let .ran(detail) = outcome(trace) else {
            Issue.record("expected .ran, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(detail.contains("every block's counts are free given its margins"))
        #expect(detail.contains("block(s) both methods read from the same integers"))
        #expect(detail.contains("x wider on the log scale"))
    }

    /// The seam, and it is the level rather than a hook.
    @Test("two levels cannot be compared, and the stage refuses rather than dividing them")
    func failedOnMismatchedLevels() async {
        var trace = PipelineTrace()
        await pipeline().auditExactAssociation(
            trace: &trace, history: fullHistory(), asymptotic: .ninetyNine
        )
        guard case let .failed(message) = outcome(trace) else {
            Issue.record("expected .failed, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(message.contains("could not be compared"))
        #expect(message.contains("exact reading at 95% cannot be compared with an asymptotic one at 99%"))
    }

    /// A block with an empty cell has no asymptotic reading at all when nothing is added to it,
    /// so there is nothing to compare against and the stage says that rather than inventing one.
    @Test("a block only one method can read is not compared, and the stage says so")
    func nothingToCompare() async throws {
        var trace = PipelineTrace()
        await pipeline().auditExactAssociation(
            trace: &trace, history: history(cells: [[12, 0, 0], [3, 9, 0], [0, 0, 0]])
        )
        guard case let .ran(detail) = outcome(trace) else {
            Issue.record("expected .ran, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(detail.contains("no block is readable by both methods on these counts"))
        #expect(detail.contains("pinned by a zero margin"))

        // The same panel read directly, to pin what "readable by one method only" means: the
        // block has an empty cell, so nothing was added to it and Woolf has no interval at all,
        // while the exact side reads it without needing one.
        let panel = try ObservedPanel(counts: [[12, 0], [3, 9]])
        #expect(try StructureMeasurement.measure(panel, policy: .structural).readings.isEmpty)
        let joint = MetadataPipeline.TransportJoint(
            key: "one-sided", panel: panel, agreedTurns: 21
        )
        guard case let .read(outcome) = MetadataPipeline.exactRead(
            joint, confidence: .ninetyFive, asymptotic: .ninetyFive, policy: .structural
        ) else {
            Issue.record("expected .read")
            return
        }
        #expect(outcome.readable == 1)
        #expect(outcome.compared == 0)
        #expect(outcome.pinned == 0)
        // The one readable block sits at the top of its support, so its exact interval is
        // unbounded above and its conservatism is not a number; it is left out rather than
        // reported as infinite.
        #expect(outcome.conservatism == 1)
    }

    /// The stage table has to name every package in the series, and this one is the reminder.
    @Test("the new stage names its package and its title")
    func catalogued() {
        #expect(PipelineStage.exactAssociation.package == "ExactAssociationKit")
        #expect(PipelineStage.exactAssociation.title == "Exact association")
    }
}
