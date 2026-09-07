import AssociationFitKit
import EffectiveVoteKit
import EvalHarness
import Foundation
import Testing
@testable import AIChatApp

/// The `associationFit` stage, which chooses the cells `squareDesign` leaves to its own method.
///
/// A three-way panel with fixed margins has nine free cells. A target agreement rate pins one.
/// This stage states the association instead, and then prices the step that turns a real-valued
/// fit into whole turns — where the margins survive exactly and the association does not.
@Suite("Association fit stage")
struct AssociationFitStageTests {
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
        trace.records.first { $0.stage == .associationFit }?.outcome
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

    @Test("a fresh install is quiet, and says why rather than reporting nothing")
    func skippedOnFreshInstall() async {
        var trace = PipelineTrace()
        await pipeline().auditAssociationFit(trace: &trace, history: ObservationHistory([]))
        guard case let .skipped(reason) = outcome(trace) else {
            Issue.record("expected .skipped, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(reason.contains("neither gate has cast one"))
    }

    @Test("one gate is not a pair")
    func noOpOnASingleGate() async {
        var trace = PipelineTrace()
        let history = ObservationHistory([
            PanelObservation(id: "t0", verdicts: [Self.answerability: .affirm], truth: nil),
            PanelObservation(id: "t1", verdicts: [Self.answerability: .deny], truth: nil)
        ])
        await pipeline().auditAssociationFit(trace: &trace, history: history)
        guard case let .noOp(reason) = outcome(trace) else {
            Issue.record("expected .noOp, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(reason.contains("there is no pair"))
    }

    @Test("two gates that voted identically are one gate for this purpose")
    func noOpOnIdenticalGates() async {
        var trace = PipelineTrace()
        await pipeline().auditAssociationFit(trace: &trace, history: identicalHistory())
        guard case let .noOp(reason) = outcome(trace) else {
            Issue.record("expected .noOp, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(reason.contains("two gates with identical margins are one gate"))
    }

    @Test("a three-way panel is fitted, rounded, and the cost of rounding reported")
    func ranOnAThreeWayPanel() async {
        var trace = PipelineTrace()
        await pipeline().auditAssociationFit(trace: &trace, history: threeWayHistory())
        guard case let .ran(detail) = outcome(trace) else {
            Issue.record("expected .ran, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(detail.contains("live verdict categories"))
        #expect(detail.contains("would agree at"))
        #expect(detail.contains("margins exact"))
        #expect(detail.contains("association shifted"))
        #expect(detail.contains("the observed panel agrees on"))
    }

    /// The seam, and it is a policy input rather than a hook.
    @Test("a control structure no distribution has is a stage failure")
    func failedOnAnImpossibleStructure() async {
        var trace = PipelineTrace()
        await pipeline().auditAssociationFit(
            trace: &trace, history: threeWayHistory(), weight: 0
        )
        guard case let .failed(message) = outcome(trace) else {
            Issue.record("expected .failed, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(message.contains("control structure refused"))
        #expect(message.contains("diagonalWeightNotPositive"))
    }

    /// The second policy input: a pass budget too small to reach the gates' rates.
    @Test("a fit that runs out of passes is a stage failure with the reason named")
    func failedWhenThePassBudgetIsTooSmall() async throws {
        var trace = PipelineTrace()
        await pipeline().auditAssociationFit(
            trace: &trace,
            history: threeWayHistory(),
            settings: try FitSettings(tolerance: 1e-12, iterationLimit: 1)
        )
        guard case let .failed(message) = outcome(trace) else {
            Issue.record("expected .failed, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(message.contains("did not reach these gates' verdict rates"))
        #expect(message.contains("didNotConverge"))
    }

    @Test("the stage table names the package that owns it")
    func stageBelongsToItsPackage() {
        #expect(PipelineStage.associationFit.package == "AssociationFitKit")
        #expect(PipelineStage.associationFit.title == "Association fit")
    }
}
