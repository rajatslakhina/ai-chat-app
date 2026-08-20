import AbstentionPolicyKit
import AgentMemoryKit
import ConformalGateKit
import ContextCompactionKit
import Foundation
import GuardrailKit
import PromptTemplateKit
import ResponseCacheKit
import RetrievalKit
import SemanticRouterKit
import Testing
@testable import AIChatApp

/// The stage that refuses on a threshold this app derived rather than one somebody chose.
@Suite("Conformal gate stage")
struct ConformalGateStageTests {
    private let answerability = PreModelPipeline.ReservationOrigin.answerability
    private let independence = PreModelPipeline.ReservationOrigin.independence

    /// Each test gets its own ledger. A shared one would let two tests certify against each
    /// other's turns, which is the same mistake as calibrating on somebody else's traffic.
    private func pipeline(ledger: CalibrationStore) async -> PreModelPipeline {
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
            calibration: ledger
        )
    }

    private func ledger() -> CalibrationStore {
        CalibrationStore(certifier: ConformalCalibration.gate, capacity: 256)
    }

    /// Twenty labelled turns: clean ones right, suspicious ones wrong.
    private func fill(_ store: CalibrationStore, count: Int = 40) async {
        for index in 0..<count {
            let score = Double(index % 10) / 10.0
            await store.record(
                CalibrationPoint(id: "seed-\(index)", score: score, wasWrong: score >= 0.7)
            )
        }
    }

    @Test("a turn where no gate filed anything is skipped, not silently passed over")
    func nothingFiled() async {
        var trace = PipelineTrace()
        let refusal = await pipeline(ledger: ledger()).gateOnCertifiedRisk(
            ledger: ledger(),
            trace: &trace
        )
        #expect(refusal == nil)
        guard case let .skipped(reason) = trace.outcome(for: .conformalGate) else {
            Issue.record("expected the stage to record why it had nothing to score")
            return
        }
        #expect(reason.contains("no gate filed"))
    }

    @Test("an empty ledger lets the turn through and says it had nothing to judge it with")
    func emptyLedgerIsANoOp() async {
        let store = ledger()
        var trace = PipelineTrace()
        PreModelPipeline.reserve(.refuse("everything is stale"), for: answerability, trace: &trace)
        let refusal = await pipeline(ledger: store).gateOnCertifiedRisk(ledger: store, trace: &trace)
        #expect(refusal == nil)
        guard case let .noOp(reason) = trace.outcome(for: .conformalGate) else {
            Issue.record("expected a no-op naming the reason it could not judge")
            return
        }
        #expect(reason.contains("score 1.00 not judged"))
        #expect(reason.contains("no calibration points"))
    }

    @Test("a ledger with some but not enough turns names the number it is still short of")
    func partiallyFilledIsANoOp() async {
        // The state this app will actually sit in for its first eighteen answered turns, and the
        // one worth reporting precisely: a gate letting everything through because it cannot yet
        // certify looks identical from outside to one that examined the turn and approved it.
        let store = ledger()
        await fill(store, count: 12)
        var trace = PipelineTrace()
        PreModelPipeline.reserve(.refuse("everything is stale"), for: answerability, trace: &trace)
        let refusal = await pipeline(ledger: store).gateOnCertifiedRisk(ledger: store, trace: &trace)
        #expect(refusal == nil)
        guard case let .noOp(reason) = trace.outcome(for: .conformalGate) else {
            Issue.record("expected a no-op naming the shortfall")
            return
        }
        #expect(reason.contains("12 calibration points cannot certify alpha 0.050; 19 are needed"))
    }

    @Test("a certified threshold admits a clean turn, and records that it examined it")
    func certifiedAdmits() async {
        let store = ledger()
        await fill(store)
        var trace = PipelineTrace()
        PreModelPipeline.reserve(.clear, for: answerability, trace: &trace)
        PreModelPipeline.reserve(.clear, for: independence, trace: &trace)
        let refusal = await pipeline(ledger: store).gateOnCertifiedRisk(ledger: store, trace: &trace)
        #expect(refusal == nil)
        guard case let .ran(detail) = trace.outcome(for: .conformalGate) else {
            Issue.record("expected the stage to record that it judged the score")
            return
        }
        #expect(detail.contains("inside the certified threshold"))
    }

    @Test("a certified threshold refuses a suspicious turn, and the refusal reaches the user")
    func certifiedRefuses() async {
        let store = ledger()
        await fill(store)
        var trace = PipelineTrace()
        PreModelPipeline.reserve(.refuse("all passages are stale"), for: answerability, trace: &trace)
        PreModelPipeline.reserve(.refuse("nothing survived"), for: independence, trace: &trace)
        let refusal = await pipeline(ledger: store).gateOnCertifiedRisk(ledger: store, trace: &trace)
        guard let refusal else {
            Issue.record("a score of 1.0 must be outside any threshold certified at alpha 0.05")
            return
        }
        #expect(refusal.stage == .conformalGate)
        #expect(!refusal.headline.isEmpty)
        #expect(refusal.explanation.contains("above the certified threshold"))
        #expect(refusal.explanation.contains("answered turns"))
        #expect(refusal.recovery == .openSettings(field: "Retrieval"))
        #expect(trace.outcome(for: .conformalGate)?.isRefusal == true)
    }

    @Test("the stage files no reservation, because its score is the other gates' opinion")
    func filesNoReservation() async {
        let store = ledger()
        await fill(store)
        var trace = PipelineTrace()
        PreModelPipeline.reserve(.concern(.low, "thin"), for: answerability, trace: &trace)
        let before = trace.reservations.count
        _ = await pipeline(ledger: store).gateOnCertifiedRisk(ledger: store, trace: &trace)
        #expect(trace.reservations.count == before)
    }
}

/// Deriving a score from readings, and a label from what the answer stages decided.
@Suite("Conformal calibration")
struct ConformalCalibrationTests {
    private let answerability = PreModelPipeline.ReservationOrigin.answerability

    @Test("a turn with no readings has no score, which is not a score of zero")
    func absentIsNotZero() {
        #expect(ConformalCalibration.score(for: []) == nil)
    }

    @Test("the scale runs clear, concern, unavailable, refusal")
    func ordering() {
        func score(_ reading: SignalReading) -> Double? {
            ConformalCalibration.score(for: [AbstentionSignal(origin: SignalOrigin("g"), reading: reading)])
        }
        #expect(score(.clear) == 0)
        #expect(score(.concern(.low, "x")) == 0.5)
        #expect(score(.concern(.high, "x")) == 0.7000000000000001)
        #expect(score(.unavailable("x")) == 0.6)
        #expect(score(.refuse("x")) == 1.0)
    }

    @Test("a verification refusal is what makes a turn wrong")
    func labelComesFromTheAnswerStages() {
        var trace = PipelineTrace()
        trace.record(.grounding, .ran(detail: "all claims grounded"))
        #expect(!ConformalCalibration.answeringWasWrong(trace))

        var refused = PipelineTrace()
        refused.record(.claimConsistency, .refused(
            Refusal(stage: .claimConsistency, headline: "h", explanation: "e", recovery: nil)
        ))
        #expect(ConformalCalibration.answeringWasWrong(refused))
    }

    @Test("a privacy refusal is not a truthfulness one, and does not label the turn wrong")
    func guardrailIsNotALabel() {
        var trace = PipelineTrace()
        trace.record(.guardrailOutput, .refused(
            Refusal(stage: .guardrailOutput, headline: "h", explanation: "e", recovery: nil)
        ))
        #expect(!ConformalCalibration.answeringWasWrong(trace))
    }

    @Test("a turn is only labelled when it has both a score and a verdict")
    func pointsRequireBoth() {
        var noReadings = PipelineTrace()
        noReadings.record(.grounding, .ran(detail: "fine"))
        #expect(ConformalCalibration.point(id: "a", trace: noReadings) == nil)

        var noVerdict = PipelineTrace()
        PreModelPipeline.reserve(.concern(.low, "thin"), for: answerability, trace: &noVerdict)
        #expect(ConformalCalibration.point(id: "b", trace: noVerdict) == nil)

        var complete = PipelineTrace()
        PreModelPipeline.reserve(.concern(.low, "thin"), for: answerability, trace: &complete)
        complete.record(.grounding, .ran(detail: "fine"))
        let point = ConformalCalibration.point(id: "c", trace: complete)
        #expect(point?.score == 0.5)
        #expect(point?.wasWrong == false)
    }
}
