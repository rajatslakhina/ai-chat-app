import EffectiveVoteKit
import EvalHarness
import Foundation
import PanelDesignKit
import Testing
@testable import AIChatApp

/// The `panelDesign` stage, which audits the fixture its five siblings compute over.
///
/// `effectiveVote`, `sampleWidth`, `familyError`, `effectiveComparison` and `chanceAgreement` all
/// price how much two gates agree, and all of them price it over the same affirm grid. This stage
/// asks the question none of them asks: can that grid hold an association at all. The suite pins
/// each answer it can give — forced agreement, a pinned rate, a wholly null panel, and the repair
/// preview that says what a fixture carrying the target would look like.
@Suite("Panel design stage")
struct PanelDesignStageTests {
    private static let answerability = JudgeIdentity("answerability")
    private static let stability = JudgeIdentity("verdict stability")
    private static let independence = JudgeIdentity("source independence")

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
        trace.records.first { $0.stage == .panelDesign }?.outcome
    }

    /// Three gates with different affirm-rates, and a real association between two of them.
    private func spreadHistory(count: Int = 40) -> ObservationHistory {
        ObservationHistory((0..<count).map { index in
            PanelObservation(
                id: "turn-\(index)",
                verdicts: [
                    Self.answerability: index % 10 < 8 ? .affirm : .deny,
                    Self.stability: index % 10 < 7 ? .affirm : .deny,
                    Self.independence: index % 10 < 4 ? .affirm : .deny
                ],
                truth: nil
            )
        })
    }

    /// A gate that affirmed every turn, beside two that did not and agree with each other.
    ///
    /// The third gate is there because a constant gate is null against *everything* — its joint
    /// counts are the other gate's marginal, which is exactly what independence predicts — so a
    /// panel of only a constant gate and one other reports the wholly-null outcome rather than
    /// the pinned one.
    private func constantHistory(count: Int = 20) -> ObservationHistory {
        ObservationHistory((0..<count).map { index in
            PanelObservation(
                id: "turn-\(index)",
                verdicts: [
                    Self.answerability: .affirm,
                    Self.stability: index % 4 == 0 ? .deny : .affirm,
                    Self.independence: index % 4 == 0 ? .deny : .affirm
                ],
                truth: nil
            )
        })
    }

    /// Two gates crossed with each other, so every joint count is a product of the marginals.
    private func crossedHistory(repeats: Int = 10) -> ObservationHistory {
        var observations: [PanelObservation] = []
        for round in 0..<repeats {
            for combination in 0..<4 {
                observations.append(
                    PanelObservation(
                        id: "turn-\(round)-\(combination)",
                        verdicts: [
                            Self.answerability: combination & 2 == 0 ? .affirm : .deny,
                            Self.stability: combination & 1 == 0 ? .affirm : .deny
                        ],
                        truth: nil
                    )
                )
            }
        }
        return ObservationHistory(observations)
    }

    @Test("a fresh install is quiet, and says why rather than reporting nothing")
    func skippedOnFreshInstall() async {
        var trace = PipelineTrace()
        await pipeline().auditPanelDesign(trace: &trace, history: ObservationHistory([]))
        guard case let .skipped(reason) = outcome(trace) else {
            Issue.record("expected .skipped, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(reason.contains("no gate has affirmed anything"))
    }

    @Test("one gate is not a pair, and the stage says so instead of failing")
    func noOpOnASingleGate() async {
        var trace = PipelineTrace()
        let history = ObservationHistory([
            PanelObservation(id: "t0", verdicts: [Self.answerability: .affirm], truth: nil),
            PanelObservation(id: "t1", verdicts: [Self.answerability: .deny], truth: nil)
        ])
        await pipeline().auditPanelDesign(trace: &trace, history: history)
        guard case let .noOp(reason) = outcome(trace) else {
            Issue.record("expected .noOp, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(reason.contains("there is no pair"))
    }

    @Test("a single turn is fewer than a fixture needs")
    func noOpOnOneTurn() async {
        var trace = PipelineTrace()
        let history = ObservationHistory([
            PanelObservation(
                id: "t0",
                verdicts: [Self.answerability: .affirm, Self.stability: .deny],
                truth: nil
            )
        ])
        await pipeline().auditPanelDesign(trace: &trace, history: history)
        guard case let .noOp(reason) = outcome(trace) else {
            Issue.record("expected .noOp, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(reason.contains("fewer than the two a fixture needs"))
    }

    @Test("a spread panel reports the agreement its affirm-rates force before any gate speaks")
    func ranOnASpreadPanel() async {
        var trace = PipelineTrace()
        await pipeline().auditPanelDesign(trace: &trace, history: spreadHistory())
        guard case let .ran(detail) = outcome(trace) else {
            Issue.record("expected .ran, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(detail.contains("3 pair(s) of gates"))
        #expect(detail.contains("forced to agree on a share of turns"))
        #expect(detail.contains("narrowest attainable band"))
    }

    /// A constant gate is null against everything, and the message has to say which null it is.
    @Test("a constant gate is null for a blunter reason, and the outcome names it")
    func noOpNamesTheConstantGate() async {
        var trace = PipelineTrace()
        let history = ObservationHistory((0..<20).map { index in
            PanelObservation(
                id: "turn-\(index)",
                verdicts: [
                    Self.answerability: .affirm,
                    Self.stability: index % 4 == 0 ? .deny : .affirm
                ],
                truth: nil
            )
        })
        await pipeline().auditPanelDesign(trace: &trace, history: history)
        guard case let .noOp(reason) = outcome(trace) else {
            Issue.record("expected .noOp, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(reason.contains("a gate that never says no is independent of everything"))
    }

    @Test("a gate that affirmed every turn pins the rate rather than comparing two gates")
    func ranOnAPinnedPanel() async {
        var trace = PipelineTrace()
        await pipeline().auditPanelDesign(trace: &trace, history: constantHistory())
        guard case let .ran(detail) = outcome(trace) else {
            Issue.record("expected .ran, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(detail.contains("pinned to a single value"))
    }

    @Test("a crossed panel is nil by construction, and that is the finding")
    func noOpOnAWhollyNullPanel() async {
        var trace = PipelineTrace()
        await pipeline().auditPanelDesign(trace: &trace, history: crossedHistory())
        guard case let .noOp(reason) = outcome(trace) else {
            Issue.record("expected .noOp, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(reason.contains("nil by construction rather than small by measurement"))
        #expect(reason.contains("estimating zero"))
        #expect(reason.contains("enumerates its combinations evenly"))
    }

    /// The seam, and it is a policy input rather than a hook.
    ///
    /// What counts as enough association to be worth measuring is a choice. Handing the stage a
    /// target no joint distribution has is a real way for it to fail, so `.failed` is recorded
    /// for a real reason rather than by a catch-all nothing can reach.
    @Test("a target no distribution has is a stage failure, not a panel finding")
    func failedOnAnImpossibleTarget() async {
        var trace = PipelineTrace()
        await pipeline().auditPanelDesign(
            trace: &trace, history: crossedHistory(), target: .oddsRatio(0)
        )
        guard case let .failed(message) = outcome(trace) else {
            Issue.record("expected .failed, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(message.contains("panel repair preview refused"))
        #expect(message.contains("oddsRatioNotPositive"))
    }

    /// Two gates crossed, plus a third that duplicates the first.
    ///
    /// Two of the three pairs are exactly null and one is not, so the panel is not wholly null
    /// and the repair preview runs on the first null pair it finds.
    private func partlyNullHistory(repeats: Int = 10) -> ObservationHistory {
        var observations: [PanelObservation] = []
        for round in 0..<repeats {
            for combination in 0..<4 {
                let affirms = combination & 2 == 0
                observations.append(
                    PanelObservation(
                        id: "turn-\(round)-\(combination)",
                        verdicts: [
                            Self.answerability: affirms ? .affirm : .deny,
                            Self.stability: combination & 1 == 0 ? .affirm : .deny,
                            Self.independence: affirms ? .affirm : .deny
                        ],
                        truth: nil
                    )
                )
            }
        }
        return ObservationHistory(observations)
    }

    @Test("the repair preview names a rate a fixture on the same marginals would reach")
    func repairPreviewIsReported() async {
        var trace = PipelineTrace()
        await pipeline().auditPanelDesign(trace: &trace, history: partlyNullHistory())
        guard case let .ran(detail) = outcome(trace) else {
            Issue.record("expected .ran, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(detail.contains("carrying the audit's target would agree at"))
    }

    @Test("matching affirm-rates forbid agreeing on all but one turn")
    func identicalMarginalsAreReported() async {
        var trace = PipelineTrace()
        let history = ObservationHistory((0..<20).map { index in
            PanelObservation(
                id: "turn-\(index)",
                verdicts: [
                    Self.answerability: index % 4 == 0 ? .deny : .affirm,
                    Self.stability: index % 4 == 1 ? .deny : .affirm
                ],
                truth: nil
            )
        })
        await pipeline().auditPanelDesign(trace: &trace, history: history)
        guard case let .ran(detail) = outcome(trace) else {
            Issue.record("expected .ran, got \(String(describing: outcome(trace)))")
            return
        }
        #expect(detail.contains("forbids"))
        #expect(detail.contains("all-but-one turn"))
    }

    @Test("the stage table names the package that owns it")
    func stageBelongsToItsPackage() {
        #expect(PipelineStage.panelDesign.package == "PanelDesignKit")
        #expect(PipelineStage.panelDesign.title == "Panel design")
    }

    @Test("the repair enum distinguishes nothing to repair from a refused target")
    func repairOutcomesAreDistinct() {
        #expect(MetadataPipeline.DesignRepair.none != .refused("x"))
        #expect(
            MetadataPipeline.DesignRepair.built(agreement: 0.5, snapped: 0)
                != .built(agreement: 0.6, snapped: 0)
        )
    }
}
