import AbstentionPolicyKit
import AgentMemoryKit
import CensoredFeedbackKit
import ConformalGateKit
import ContextCompactionKit
import ExplorationChannelKit
import Foundation
import GuardrailKit
import PromptTemplateKit
import ResponseCacheKit
import RetrievalKit
import SemanticRouterKit
import Testing
@testable import AIChatApp

/// The only stage in this app that overrides a refusal the certificate actually supports.
///
/// These tests exercise the stage rather than the stage table. `PipelineTraceTests` asserts that
/// every package has a case in `PipelineStage`, which is a claim about a switch statement and not
/// about whether anything runs — a stage can be in the table and wired to nothing.
@Suite("Exploration channel stage")
struct ExplorationChannelStageTests {
    private let answerability = PreModelPipeline.ReservationOrigin.answerability

    private func pipeline(
        ledger: CalibrationStore,
        censoring: FeedbackLedger? = nil,
        exploration: ExplorationChannel? = nil
    ) async -> PreModelPipeline {
        let prompts = PromptRegistry()
        _ = try? await prompts.register(name: "chat.system", template: "You are terse.")
        return PreModelPipeline(
            prompts: prompts,
            guardrail: GuardrailPipeline(policy: GuardrailPolicy()),
            router: SemanticRouter(),
            cache: ResponseCache(capacity: 4),
            memory: MemoryStore(),
            retriever: Retriever(embedder: HashingEmbeddingProvider()),
            compactor: ContextCompactor(strategies: [SlidingWindowCompactionStrategy()]),
            calibration: ledger,
            censoring: censoring,
            exploration: exploration
        )
    }

    private func calibrationStore() -> CalibrationStore {
        CalibrationStore(certifier: ConformalCalibration.gate, capacity: 256)
    }

    private func feedbackLedger() -> FeedbackLedger? {
        (try? CensoringAuditor(lossBound: 1, budget: 0.05))
            .flatMap { FeedbackLedger(capacity: 256, auditor: $0) }
    }

    private func fill(_ store: CalibrationStore, count: Int = 40) async {
        for index in 0..<count {
            let score = Double(index % 10) / 10.0
            await store.record(CalibrationPoint(id: "seed-\(index)", score: score, wasWrong: score >= 0.7))
        }
    }

    /// A channel that admits everything inside its region, so the draw is never what is under test.
    private func certainChannel(reach: Double = 1.0, budget: Double = 10) -> ExplorationChannel? {
        guard let region = try? ExplorationRegion(lowerBound: -reach, threshold: 0, frequency: 1) else {
            return nil
        }
        return try? ExplorationChannel(
            region: region,
            budget: budget,
            costModel: LinearExplorationCost(unitCost: 1),
            sampler: ExhaustiveSampler()
        )
    }

    private func refusal(stage: PipelineStage) -> Refusal {
        Refusal(stage: stage, headline: "h", explanation: "e", recovery: nil)
    }

    @Test("a turn nobody refused is a no-op, not an exploration")
    func nothingRefused() async {
        var trace = PipelineTrace()
        let store = calibrationStore()
        let result = await pipeline(ledger: store, exploration: certainChannel())
            .exploreRefusedTurn(refusal: nil, ledger: store, channel: certainChannel(), trace: &trace)
        #expect(result == nil)
        guard case let .noOp(reason) = trace.outcome(for: .explorationChannel) else {
            Issue.record("expected a no-op")
            return
        }
        #expect(reason.contains("nothing was refused"))
    }

    @Test("only a certified-risk refusal is explorable — a judging gate's stands untouched")
    func onlyConformalRefusalsAreExplorable() async {
        // The load-bearing constraint. A stage that can loosen gates must never be able to loosen
        // the ones that judge whether the evidence supports an answer at all.
        for stage in [PipelineStage.answerabilityGate, .abstentionArbiter, .guardrailInput] {
            var trace = PipelineTrace()
            let store = calibrationStore()
            await fill(store)
            let standing = refusal(stage: stage)
            let result = await pipeline(ledger: store, exploration: certainChannel())
                .exploreRefusedTurn(
                    refusal: standing,
                    ledger: store,
                    channel: certainChannel(),
                    trace: &trace
                )
            #expect(result == standing)
            guard case let .skipped(reason) = trace.outcome(for: .explorationChannel) else {
                Issue.record("expected a skip for \(stage)")
                return
            }
            #expect(reason.contains("only a certified-risk refusal is explorable"))
        }
    }

    @Test("with no budget configured the refusal stands and the stage says why")
    func noChannel() async {
        var trace = PipelineTrace()
        let store = calibrationStore()
        await fill(store)
        let standing = refusal(stage: .conformalGate)
        let result = await pipeline(ledger: store)
            .exploreRefusedTurn(refusal: standing, ledger: store, channel: nil, trace: &trace)
        #expect(result == standing)
        guard case let .skipped(reason) = trace.outcome(for: .explorationChannel) else {
            Issue.record("expected a skip")
            return
        }
        #expect(reason.contains("no exploration budget configured"))
    }

    @Test("with nothing scored there is no depth to measure and the refusal stands")
    func noScore() async {
        var trace = PipelineTrace()
        let store = calibrationStore()
        await fill(store)
        let standing = refusal(stage: .conformalGate)
        let result = await pipeline(ledger: store, exploration: certainChannel())
            .exploreRefusedTurn(
                refusal: standing,
                ledger: store,
                channel: certainChannel(),
                trace: &trace
            )
        #expect(result == standing)
        guard case let .skipped(reason) = trace.outcome(for: .explorationChannel) else {
            Issue.record("expected a skip")
            return
        }
        #expect(reason.contains("no scored threshold"))
    }

    @Test("an uncalibrated gate has no threshold, so nothing is explorable yet")
    func noCertificate() async {
        var trace = PipelineTrace()
        let store = calibrationStore()
        PreModelPipeline.reserve(.refuse("everything is stale"), for: answerability, trace: &trace)
        let standing = refusal(stage: .conformalGate)
        let result = await pipeline(ledger: store, exploration: certainChannel())
            .exploreRefusedTurn(
                refusal: standing,
                ledger: store,
                channel: certainChannel(),
                trace: &trace
            )
        #expect(result == standing)
        guard case let .skipped(reason) = trace.outcome(for: .explorationChannel) else {
            Issue.record("expected a skip")
            return
        }
        #expect(reason.contains("no scored threshold"))
    }

    @Test("an affordable refusal inside the region is answered, and the refusal is withdrawn")
    func admits() async {
        var trace = PipelineTrace()
        let store = calibrationStore()
        await fill(store)
        let channel = certainChannel()
        let censoring = feedbackLedger()
        PreModelPipeline.reserve(.refuse("everything is stale"), for: answerability, trace: &trace)

        let result = await pipeline(ledger: store, censoring: censoring, exploration: channel)
            .exploreRefusedTurn(
                refusal: refusal(stage: .conformalGate),
                ledger: store,
                channel: channel,
                trace: &trace
            )

        #expect(result == nil)
        guard case let .ran(detail) = trace.outcome(for: .explorationChannel) else {
            Issue.record("expected the stage to report a real admission")
            return
        }
        #expect(detail.contains("deliberate exploration"))
        #expect(detail.contains("admission probability"))
    }

    @Test("an explored turn is logged as one that had a chance, not as a refusal")
    func recordsAChance() async {
        // The whole payoff. `CensoringFeedback.refused` logs probability zero and nothing can be
        // reweighted from it. This turn had a chance, so it carries a finite weight.
        let store = calibrationStore()
        await fill(store)
        guard let censoring = feedbackLedger() else {
            Issue.record("no ledger")
            return
        }
        await pipeline(ledger: store, censoring: censoring)
            .recordExploredTurn(id: "explore-0", probability: 0.2)

        let records = await censoring.records
        #expect(records.count == 1)
        #expect(records[0].admissionProbability == 0.2)
        #expect(records[0].observation == .censored)
        #expect(records[0].inverseProbabilityWeight != nil)

        let refused = CensoringFeedback.refused(id: "refused-0", score: 0.1, threshold: 0.5)
        #expect(refused.inverseProbabilityWeight == nil)
    }

    @Test("a refusal deeper than the region is unreachable at any budget")
    func outsideRegion() async {
        var trace = PipelineTrace()
        let store = calibrationStore()
        await fill(store)
        // A region reaching 0.001 in score, against an enormous budget.
        let narrow = certainChannel(reach: 0.001, budget: 1_000_000)
        PreModelPipeline.reserve(.refuse("everything is stale"), for: answerability, trace: &trace)

        let standing = refusal(stage: .conformalGate)
        let result = await pipeline(ledger: store, exploration: narrow)
            .exploreRefusedTurn(refusal: standing, ledger: store, channel: narrow, trace: &trace)

        #expect(result == standing)
        guard case let .noOp(reason) = trace.outcome(for: .explorationChannel) else {
            Issue.record("expected a no-op naming the region")
            return
        }
        #expect(reason.contains("beyond what this app explores at any budget"))
    }

    @Test("an exhausted budget leaves the refusal standing and says how little is left")
    func tooCostly() async {
        var trace = PipelineTrace()
        let store = calibrationStore()
        await fill(store)
        let broke = certainChannel(reach: 1, budget: 0.0001)
        PreModelPipeline.reserve(.refuse("everything is stale"), for: answerability, trace: &trace)

        let standing = refusal(stage: .conformalGate)
        let result = await pipeline(ledger: store, exploration: broke)
            .exploreRefusedTurn(refusal: standing, ledger: store, channel: broke, trace: &trace)

        #expect(result == standing)
        guard case let .noOp(reason) = trace.outcome(for: .explorationChannel) else {
            Issue.record("expected a no-op about cost")
            return
        }
        #expect(reason.contains("of budget left"))
    }

    @Test("a candidate in region and affordable but not drawn leaves the refusal standing")
    func notDrawn() async {
        var trace = PipelineTrace()
        let store = calibrationStore()
        await fill(store)
        guard let region = try? ExplorationRegion(lowerBound: -1, threshold: 0, frequency: 0.5),
              let channel = try? ExplorationChannel(
                  region: region,
                  budget: 10,
                  costModel: LinearExplorationCost(unitCost: 1),
                  sampler: NeverDrawsSampler()
              ) else {
            Issue.record("could not build channel")
            return
        }
        PreModelPipeline.reserve(.refuse("everything is stale"), for: answerability, trace: &trace)

        let standing = refusal(stage: .conformalGate)
        let result = await pipeline(ledger: store, exploration: channel)
            .exploreRefusedTurn(refusal: standing, ledger: store, channel: channel, trace: &trace)

        #expect(result == standing)
        guard case let .noOp(reason) = trace.outcome(for: .explorationChannel) else {
            Issue.record("expected a no-op about the draw")
            return
        }
        #expect(reason.contains("not drawn this turn"))
    }

    @Test("a refusal whose score is inside the threshold is a disagreement, not an exploration")
    func refusalAndScoreDisagree() async {
        // The gate says refuse; the score says the turn is inside the certified threshold. That is
        // the two disagreeing, and exploring on it would spend budget on a turn nothing actually
        // objected to. A mild reservation against a store whose threshold is high produces exactly
        // this.
        var trace = PipelineTrace()
        let store = calibrationStore()
        await fill(store)
        PreModelPipeline.reserve(.concern(.low, "thin"), for: answerability, trace: &trace)
        let channel = certainChannel()

        let standing = refusal(stage: .conformalGate)
        let result = await pipeline(ledger: store, exploration: channel)
            .exploreRefusedTurn(refusal: standing, ledger: store, channel: channel, trace: &trace)

        #expect(result == standing)
        guard case let .skipped(reason) = trace.outcome(for: .explorationChannel) else {
            Issue.record("expected a skip naming the disagreement")
            return
        }
        #expect(reason.contains("inside the threshold"))
    }

    @Test("the orientation adapter puts a refused turn at positive depth")
    func orientation() {
        // Conformal refuses above its threshold; a channel refuses below. A flip that went
        // unnoticed would explore the turns the gate was most comfortable with.
        let candidate = ExplorationBudget.candidate(id: "a", score: 0.8, threshold: 0.5)
        #expect(candidate.wasRefused)
        #expect(abs(candidate.depth - 0.3) < 1e-9)

        let admitted = ExplorationBudget.candidate(id: "b", score: 0.2, threshold: 0.5)
        #expect(!admitted.wasRefused)
    }

    @Test("the app's own budget is well-formed")
    func sharedBudget() async {
        guard let region = ExplorationBudget.region else {
            Issue.record("the app's region should be constructible")
            return
        }
        #expect(abs(region.maximumDepth - ExplorationBudget.reach) < 1e-9)
        #expect(region.frequency == ExplorationBudget.frequency)
        #expect(ExplorationBudget.shared != nil)
        #expect(await ExplorationBudget.shared?.budget == ExplorationBudget.budget)
    }

    @Test("the stage belongs to its package and has a title")
    func tableEntry() {
        #expect(PipelineStage.explorationChannel.package == "ExplorationChannelKit")
        #expect(PipelineStage.explorationChannel.title == "Exploration channel")
    }
}

/// Never draws, so the "in region, affordable, not drawn" path can be reached without depending on
/// which ids a real sampler happens to pick.
private struct NeverDrawsSampler: RefusalSampler {
    func draws(_ candidate: RefusalCandidate, frequency: Double) -> Bool {
        _ = candidate
        _ = frequency
        return false
    }
}
