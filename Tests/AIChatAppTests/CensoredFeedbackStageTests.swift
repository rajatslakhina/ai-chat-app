import AbstentionPolicyKit
import AgentMemoryKit
import CensoredFeedbackConformal
import CensoredFeedbackKit
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

/// The stage that decides whether the gate below it is allowed to refuse anybody.
@Suite("Censored feedback stage")
struct CensoredFeedbackStageTests {
    private let answerability = PreModelPipeline.ReservationOrigin.answerability

    private func pipeline(
        ledger: CalibrationStore,
        censoring: FeedbackLedger?
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
            censoring: censoring
        )
    }

    private func calibrationStore() -> CalibrationStore {
        CalibrationStore(certifier: ConformalCalibration.gate, capacity: 256)
    }

    private func feedbackLedger() -> FeedbackLedger? {
        (try? CensoringAuditor(lossBound: 1, budget: 0.05))
            .flatMap { FeedbackLedger(capacity: 256, auditor: $0) }
    }

    /// Forty labelled turns: clean ones right, suspicious ones wrong. Certifies at alpha 0.05.
    private func fill(_ store: CalibrationStore, count: Int = 40) async {
        for index in 0..<count {
            let score = Double(index % 10) / 10.0
            await store.record(CalibrationPoint(id: "seed-\(index)", score: score, wasWrong: score >= 0.7))
        }
    }

    /// A decision log whose bound is tight enough to support a 0.05 budget.
    private func fillAnswered(_ ledger: FeedbackLedger, count: Int, wrong: Int) async {
        for index in 0..<count {
            try? await ledger.record(CensoringFeedback.answered(id: "ok-\(index)", wasWrong: index < wrong))
        }
    }

    @Test("with no certificate there is nothing to qualify, and it says so")
    func noCertificate() async {
        var trace = PipelineTrace()
        let store = calibrationStore()
        let support = await pipeline(ledger: store, censoring: feedbackLedger())
            .qualifyCertifiedRisk(ledger: store, censoring: feedbackLedger(), trace: &trace)
        #expect(support == nil)
        guard case let .skipped(reason) = trace.outcome(for: .censoredFeedback) else {
            Issue.record("expected a skip naming the missing certificate")
            return
        }
        #expect(reason.contains("no certificate to qualify"))
    }

    @Test("with no decision log the stage cannot run, and does not pretend to")
    func noLedger() async {
        var trace = PipelineTrace()
        let store = calibrationStore()
        await fill(store)
        let support = await pipeline(ledger: store, censoring: nil)
            .qualifyCertifiedRisk(ledger: store, censoring: nil, trace: &trace)
        #expect(support == nil)
        #expect(trace.outcome(for: .censoredFeedback) == .skipped(reason: "no decision log configured"))
    }

    @Test("a duplicated identifier makes the audit fail, and the failure is recorded not swallowed")
    func auditFails() async {
        var trace = PipelineTrace()
        let store = calibrationStore()
        await fill(store)
        guard let censoring = feedbackLedger() else {
            Issue.record("the ledger's own construction must not fail")
            return
        }
        try? await censoring.record(CensoringFeedback.answered(id: "dup", wasWrong: false))
        try? await censoring.record(CensoringFeedback.answered(id: "dup", wasWrong: true))
        let support = await pipeline(ledger: store, censoring: censoring)
            .qualifyCertifiedRisk(ledger: store, censoring: censoring, trace: &trace)
        #expect(support == nil)
        #expect(trace.outcome(for: .censoredFeedback) == .failed(message: "the decision log could not be audited"))
    }

    @Test("an unlabelled refusal wide enough to breach the budget withdraws enforcement")
    func withdrawsEnforcement() async {
        var trace = PipelineTrace()
        let store = calibrationStore()
        await fill(store)
        guard let censoring = feedbackLedger() else { return }
        // Fifteen answered and one unknown: the single unlabelled turn can move the population
        // mean by 1/16 = 0.0625, which is outside 0.05. At twenty answered it could move it by
        // 1/21 = 0.0476 and the promise would survive — the size of the log is the whole point.
        await fillAnswered(censoring, count: 15, wrong: 0)
        try? await censoring.record(CensoringFeedback.refused(id: "r0", score: 0.1, threshold: 0.5))
        let support = await pipeline(ledger: store, censoring: censoring)
            .qualifyCertifiedRisk(ledger: store, censoring: censoring, trace: &trace)
        #expect(support?.allowsEnforcement == false)
        guard case let .ran(detail) = trace.outcome(for: .censoredFeedback) else {
            Issue.record("qualifying a certificate is work whichever way it comes out")
            return
        }
        #expect(detail.contains("enforcement withdrawn"))
        #expect(detail.contains("1 of 16 decisions unlabelled"))
    }

    @Test("a log with nothing unknown and a loss inside the budget keeps the promise standing")
    func upholdsEnforcement() async {
        var trace = PipelineTrace()
        let store = calibrationStore()
        await fill(store)
        guard let censoring = feedbackLedger() else { return }
        await fillAnswered(censoring, count: 60, wrong: 1)
        let support = await pipeline(ledger: store, censoring: censoring)
            .qualifyCertifiedRisk(ledger: store, censoring: censoring, trace: &trace)
        #expect(support?.allowsEnforcement == true)
        guard case let .ran(detail) = trace.outcome(for: .censoredFeedback) else {
            Issue.record("expected the stage to record that the certificate holds")
            return
        }
        #expect(detail.contains("certificate holds over all 60 decisions"))
    }

    @Test("a withdrawn certificate stops the gate refusing, and the gate says why")
    func gateStandsDown() async {
        var trace = PipelineTrace()
        let store = calibrationStore()
        await fill(store)
        PreModelPipeline.reserve(.refuse("nothing supports this"), for: answerability, trace: &trace)
        let refusal = await pipeline(ledger: store, censoring: feedbackLedger()).gateOnCertifiedRisk(
            ledger: store,
            enforcement: .unsupported(reason: "the decision log is empty, so nothing supports the bound"),
            trace: &trace
        )
        #expect(refusal == nil)
        guard case let .skipped(reason) = trace.outcome(for: .conformalGate) else {
            Issue.record("a gate that stands down must record that it did")
            return
        }
        #expect(reason.contains("enforcement withdrawn"))
    }

    @Test("a supported certificate leaves the gate free to refuse exactly as before")
    func gateStillRefuses() async {
        var trace = PipelineTrace()
        let store = calibrationStore()
        await fill(store)
        PreModelPipeline.reserve(.refuse("nothing supports this"), for: answerability, trace: &trace)
        let refusal = await pipeline(ledger: store, censoring: feedbackLedger()).gateOnCertifiedRisk(
            ledger: store,
            enforcement: .supported(upperBound: 0.01),
            trace: &trace
        )
        #expect(refusal?.stage == .conformalGate)
    }
}

/// The record builders, which decide which of three things is known about a turn.
@Suite("Censoring feedback records")
struct CensoringFeedbackRecordTests {
    @Test("an answered turn carries its verdict as the loss")
    func answered() {
        #expect(CensoringFeedback.answered(id: "a", wasWrong: true).observation == .observed(1))
        #expect(CensoringFeedback.answered(id: "b", wasWrong: false).observation == .observed(0))
        #expect(CensoringFeedback.answered(id: "c", wasWrong: false).admissionProbability == 1)
    }

    @Test("a refusal above the threshold is pinned at zero; at or below it, it is unknown")
    func refused() {
        #expect(CensoringFeedback.refused(id: "a", score: 0.9, threshold: 0.5).observation == .determined(0))
        #expect(CensoringFeedback.refused(id: "b", score: 0.5, threshold: 0.5).observation == .censored)
        #expect(CensoringFeedback.refused(id: "c", score: 0.1, threshold: 0.5).observation == .censored)
        #expect(CensoringFeedback.refused(id: "d", score: 0.9, threshold: nil).observation == .censored)
        #expect(CensoringFeedback.refused(id: "e", score: 0.9, threshold: 0.5).admissionProbability == 0)
    }

    @Test("the app's own ledger is constructible, which is why nothing force-unwraps it")
    func ledgerExists() async {
        #expect(CensoringLedger.shared != nil)
        #expect(CensoringFeedback.budget == 0.05)
    }
}

/// Recording the refused half of the population, which is what makes the audit mean anything.
@Suite("Recording refused turns")
struct RecordRefusedTurnTests {
    private let answerability = PreModelPipeline.ReservationOrigin.answerability

    private func pipeline(censoring: FeedbackLedger?) async -> PreModelPipeline {
        PreModelPipeline(
            prompts: PromptRegistry(),
            guardrail: GuardrailPipeline(policy: GuardrailPolicy()),
            router: SemanticRouter(),
            cache: ResponseCache(capacity: 4),
            memory: MemoryStore(),
            retriever: Retriever(embedder: HashingEmbeddingProvider()),
            compactor: ContextCompactor(strategies: [SlidingWindowCompactionStrategy()]),
            calibration: CalibrationStore(certifier: ConformalCalibration.gate, capacity: 4),
            censoring: censoring
        )
    }

    @Test("a refused turn that nothing scored is not in the population at all")
    func unscoredTurnIsNotRecorded() async {
        guard let censoring = (try? CensoringAuditor())
            .flatMap({ FeedbackLedger(capacity: 8, auditor: $0) }) else { return }
        let store = CalibrationStore(certifier: ConformalCalibration.gate, capacity: 4)
        await pipeline(censoring: censoring)
            .recordRefusedTurn(ledger: store, censoring: censoring, trace: PipelineTrace())
        #expect(await censoring.count == 0)
    }

    @Test("a refused turn with a reading is recorded, and with no ledger nothing happens")
    func scoredTurnIsRecorded() async {
        guard let censoring = (try? CensoringAuditor())
            .flatMap({ FeedbackLedger(capacity: 8, auditor: $0) }) else { return }
        let store = CalibrationStore(certifier: ConformalCalibration.gate, capacity: 4)
        var trace = PipelineTrace()
        PreModelPipeline.reserve(.refuse("nothing supports this"), for: answerability, trace: &trace)
        await pipeline(censoring: censoring).recordRefusedTurn(ledger: store, censoring: censoring, trace: trace)
        #expect(await censoring.count == 1)
        #expect(await censoring.records.first?.observation == .censored)
        await pipeline(censoring: nil).recordRefusedTurn(ledger: store, censoring: nil, trace: trace)
        #expect(await censoring.count == 1)
    }
}
