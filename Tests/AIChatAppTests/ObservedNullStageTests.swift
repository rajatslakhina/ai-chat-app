import EffectiveVoteKit
import EvalHarness
import Foundation
import ObservedNullKit
import Testing
@testable import AIChatApp

/// The `observedNull` stage, which checks the assumption `effectiveComparison` spends.
///
/// Its sibling derives a correction from panel geometry and draws its threshold from a Gaussian
/// copula fitted to that structure. This stage resamples the gates' own grades instead, and
/// audits whether the structural correlation of one half is something these agreement rates
/// could produce. The suite pins all four outcomes, including the one that matters most: the
/// stage saying nothing on a fresh install, on purpose.
@Suite("Observed null stage")
struct ObservedNullStageTests {
    private static let answerability = JudgeIdentity("answerability")
    private static let stability = JudgeIdentity("verdict stability")
    private static let independence = JudgeIdentity("source independence")
    private static let temporal = JudgeIdentity("temporal validity")

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
        trace.records.first { $0.stage == .observedNull }?.outcome
    }

    /// Four gates that vary, with rates spread far enough apart to be worth auditing.
    private func spreadHistory(count: Int = 40) -> ObservationHistory {
        ObservationHistory((0..<count).map { index in
            PanelObservation(
                id: "turn-\(index)",
                verdicts: [
                    Self.answerability: index % 10 < 8 ? .affirm : .deny,
                    Self.stability: index % 10 < 7 ? .affirm : .deny,
                    Self.independence: index % 10 < 4 ? .affirm : .deny,
                    Self.temporal: index % 10 < 3 ? .affirm : .deny
                ],
                truth: nil
            )
        })
    }

    /// A gate that never changes its mind, which cannot be resampled.
    private func constantHistory(count: Int = 12) -> ObservationHistory {
        ObservationHistory((0..<count).map { index in
            PanelObservation(
                id: "turn-\(index)",
                verdicts: [
                    Self.answerability: .affirm,
                    Self.stability: index.isMultiple(of: 2) ? .affirm : .deny,
                    Self.independence: index.isMultiple(of: 3) ? .affirm : .deny,
                    Self.temporal: index.isMultiple(of: 4) ? .affirm : .deny
                ],
                truth: nil
            )
        })
    }

    @Test("the stage owns ObservedNullKit and is named in the trace")
    func catalog() {
        #expect(PipelineStage.observedNull.package == "ObservedNullKit")
        #expect(PipelineStage.observedNull.title == "Observed null")
        #expect(PipelineStage.observedNull.id == PipelineStage.observedNull.rawValue)
    }

    @Test("on a fresh install it says nothing, and says why that is the point")
    func skipsWithNoHistory() async {
        var trace = PipelineTrace()
        await pipeline().auditObservedNull(trace: &trace, history: ObservationHistory())
        guard case let .skipped(reason) = outcome(trace) else {
            Issue.record("expected a skip, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(reason.contains("no turn observed yet"))
        #expect(reason.contains("shape"))
    }

    @Test("a gate that never varies is a no-op that names the gate and the remedy")
    func noOpOnConstantGate() async {
        var trace = PipelineTrace()
        await pipeline().auditObservedNull(trace: &trace, history: constantHistory())
        guard case let .noOp(reason) = outcome(trace) else {
            Issue.record("expected a no-op, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(reason.contains("12 observed turn(s)"))
        #expect(reason.contains("graded every item the same way"))
        #expect(reason.contains("Drop the gate") || reason.contains("drop the"))
    }

    @Test("with grades to resample it prices the tail and reports the audit")
    func runsOnSpreadPanel() async {
        var trace = PipelineTrace()
        await pipeline().auditObservedNull(trace: &trace, history: spreadHistory())
        guard case let .ran(detail) = outcome(trace) else {
            Issue.record("expected a run, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(detail.contains("40 turn(s), 6 pair(s)"))
        #expect(detail.contains("resampling the panel prices its tail at"))
        #expect(detail.contains("effective comparison(s) rather than 6"))
        #expect(detail.contains("largest reading"))
        #expect(detail.contains("structural matrix"))
    }

    @Test("the panel is built from affirmations, so it survives turns with no ground truth")
    func panelNeedsNoTruth() throws {
        let panel = try MetadataPipeline.panel(from: spreadHistory())
        #expect(panel.judgeCount == 4)
        #expect(panel.itemCount == 40)
        // `ObservationHistory.judges` sorts, so the columns are alphabetical rather than in the
        // order the fixture's dictionary literal happens to list them. Pinned here because a
        // silent transposition would make every rate in this suite plausible and wrong.
        #expect(panel.judgeIdentifiers == [
            "answerability", "source independence", "temporal validity", "verdict stability"
        ])
        #expect(abs(panel.rate(ofJudge: 0) - 0.8) < 1e-9)
        #expect(abs(panel.rate(ofJudge: 1) - 0.4) < 1e-9)
        #expect(abs(panel.rate(ofJudge: 2) - 0.3) < 1e-9)
        #expect(abs(panel.rate(ofJudge: 3) - 0.7) < 1e-9)
    }

    @Test("the structural matrix is the one the sibling stage spends")
    func structuralMatrix() throws {
        let family = AgreementFamily(observations: try MetadataPipeline.panel(from: spreadHistory()))
        let matrix = MetadataPipeline.structural(family)
        #expect(matrix.count == 6)
        for row in 0..<family.size {
            #expect(matrix[row][row] == 1)
            for column in 0..<family.size where column != row {
                let shares = family.pairs[row].overlaps(family.pairs[column])
                #expect(matrix[row][column] == (shares ? 0.5 : 0))
            }
        }
    }

    /// Two gates that are exact opposites, so their one pair never agrees.
    ///
    /// Neither gate is constant, so the panel is accepted; the *pair* is, so every bootstrap
    /// replicate returns the same count and the null has no spread to take a tail from.
    private func mirroredHistory(count: Int = 20) -> ObservationHistory {
        ObservationHistory((0..<count).map { index in
            PanelObservation(
                id: "turn-\(index)",
                verdicts: [
                    Self.answerability: index.isMultiple(of: 2) ? .affirm : .deny,
                    Self.stability: index.isMultiple(of: 2) ? .deny : .affirm
                ],
                truth: nil
            )
        })
    }

    /// Three gates, two of which never disagree, so no Frechet bound exists for that pair.
    private func perfectPairHistory(count: Int = 24) -> ObservationHistory {
        ObservationHistory((0..<count).map { index in
            PanelObservation(
                id: "turn-\(index)",
                verdicts: [
                    Self.answerability: index.isMultiple(of: 2) ? .affirm : .deny,
                    Self.stability: index.isMultiple(of: 2) ? .affirm : .deny,
                    Self.independence: index.isMultiple(of: 3) ? .affirm : .deny
                ],
                truth: nil
            )
        })
    }

    /// Four gates whose pairwise agreement rates all sit near a half, where the structural
    /// correlation of one half is comfortably inside what the marginals admit.
    private func balancedHistory(count: Int = 48) -> ObservationHistory {
        ObservationHistory((0..<count).map { index in
            PanelObservation(
                id: "turn-\(index)",
                verdicts: [
                    Self.answerability: index.isMultiple(of: 2) ? .affirm : .deny,
                    Self.stability: index % 4 < 2 ? .affirm : .deny,
                    Self.independence: index % 8 < 4 ? .affirm : .deny,
                    Self.temporal: index % 16 < 8 ? .affirm : .deny
                ],
                truth: nil
            )
        })
    }

    @Test("a pair that never agrees resamples to a null with no spread, and that is a no-op")
    func noOpOnDegenerateBootstrap() async {
        var trace = PipelineTrace()
        await pipeline().auditObservedNull(trace: &trace, history: mirroredHistory())
        guard case let .noOp(reason) = outcome(trace) else {
            Issue.record("expected a no-op, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(reason.contains("20 turn(s) over 1 pair(s)"))
        #expect(reason.contains("no spread"))
        #expect(reason.contains("no tail to price"))
    }

    @Test("a pair that never disagrees leaves the attainability question with no answer")
    func attainabilityUnanswerable() async {
        var trace = PipelineTrace()
        await pipeline().auditObservedNull(trace: &trace, history: perfectPairHistory())
        guard case let .ran(detail) = outcome(trace) else {
            Issue.record("expected a run, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(detail.contains("cannot be asked here"))
        #expect(detail.contains("never disagreed"))
        #expect(detail.contains("resampling needs none"))
    }

    @Test("when every structural entry is reachable the stage says the assumption holds")
    func attainabilityHolds() async {
        var trace = PipelineTrace()
        await pipeline().auditObservedNull(trace: &trace, history: balancedHistory())
        guard case let .ran(detail) = outcome(trace) else {
            Issue.record("expected a run, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(detail.contains("every entry of the structural matrix is reachable"))
        #expect(detail.contains("the assumption underneath the fitted route holds here"))
    }

    @Test("a constant gate is refused by the package, which is what the no-op reports")
    func packageRefusesConstantGate() {
        #expect(throws: ObservedNullError.self) {
            _ = try MetadataPipeline.panel(from: constantHistory())
        }
    }
}
