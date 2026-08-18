import AbstentionPolicyKit
import AgentMemoryKit
import ContextCompactionKit
import Foundation
import GuardrailKit
import PromptTemplateKit
import ResponseCacheKit
import RetrievalKit
import SemanticRouterKit
import Testing
@testable import AIChatApp

/// The stage that exists because the four gates before it cannot hear each other.
@Suite("Abstention arbiter stage")
struct AbstentionArbiterStageTests {
    private let answerability = PreModelPipeline.ReservationOrigin.answerability
    private let temporal = PreModelPipeline.ReservationOrigin.temporal
    private let independence = PreModelPipeline.ReservationOrigin.independence
    private let stability = PreModelPipeline.ReservationOrigin.stability

    private func pipeline() async -> PreModelPipeline {
        let prompts = PromptRegistry()
        _ = try? await prompts.register(name: "chat.system", template: "You are terse.")
        return PreModelPipeline(
            prompts: prompts,
            guardrail: GuardrailPipeline(policy: GuardrailPolicy()),
            router: SemanticRouter(),
            cache: ResponseCache(capacity: 4),
            memory: MemoryStore(),
            retriever: Retriever(embedder: HashingEmbeddingProvider()),
            compactor: ContextCompactor(strategies: [SlidingWindowCompactionStrategy()])
        )
    }

    @Test("an ordinary chat turn, where every judge is inapplicable, is not stopped")
    func unretrievedTurnPasses() async {
        var trace = PipelineTrace()
        for origin in [answerability, temporal, independence, stability] {
            PreModelPipeline.reserve(.unavailable("turn is not evidence-backed"), for: origin, trace: &trace)
        }
        let refusal = await pipeline().arbitrateReservations(trace: &trace)
        #expect(refusal == nil)
        // The load-bearing assertion. Under any positive coverage floor this abstains, and the
        // app refuses ordinary conversation.
        if case let .ran(detail) = trace.outcome(for: .abstentionArbiter) {
            #expect(detail.contains("0 reservation(s)"))
        } else {
            Issue.record("expected the arbiter to report having ruled")
        }
    }

    @Test("one gate's reservation is not enough, which is the judgement each gate already made")
    func singleReservationPasses() async {
        var trace = PipelineTrace()
        PreModelPipeline.reserve(.clear, for: answerability, trace: &trace)
        PreModelPipeline.reserve(.concern(.low, "1 of 3 passage(s) no longer entitled to speak"),
                                 for: temporal, trace: &trace)
        PreModelPipeline.reserve(.clear, for: stability, trace: &trace)
        #expect(await pipeline().arbitrateReservations(trace: &trace) == nil)
    }

    @Test("two gates uneasy about different things stops a turn neither would stop")
    func concurrenceRefuses() async {
        var trace = PipelineTrace()
        PreModelPipeline.reserve(.clear, for: answerability, trace: &trace)
        PreModelPipeline.reserve(.concern(.low, "2 of 4 passage(s) no longer entitled to speak"),
                                 for: temporal, trace: &trace)
        PreModelPipeline.reserve(.concern(.moderate, "all 4 passage(s) are one source"),
                                 for: independence, trace: &trace)
        PreModelPipeline.reserve(.clear, for: stability, trace: &trace)

        let refusal = await pipeline().arbitrateReservations(trace: &trace)
        #expect(refusal != nil)
        #expect(trace.outcome(for: .abstentionArbiter)?.isRefusal == true)
    }

    @Test("the refusal reaches the user with a headline, the findings, and a recovery")
    func refusalIsActionable() async {
        var trace = PipelineTrace()
        PreModelPipeline.reserve(.concern(.low, "2 of 4 passage(s) no longer entitled to speak"),
                                 for: temporal, trace: &trace)
        PreModelPipeline.reserve(.concern(.moderate, "all 4 passage(s) are one source"),
                                 for: independence, trace: &trace)

        guard let refusal = await pipeline().arbitrateReservations(trace: &trace) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(refusal.stage == .abstentionArbiter)
        #expect(!refusal.headline.isEmpty)
        // Quoting what each gate said, not summarising. A user told "two checks were unhappy"
        // cannot tell a real problem from a fussy threshold.
        #expect(refusal.explanation.contains("no longer entitled to speak"))
        #expect(refusal.explanation.contains("are one source"))
        #expect(refusal.recovery == .openSettings(field: "Retrieval"))
        #expect(refusal.recoveryTitle == "Open Settings")
    }

    @Test("one gate cannot concur with itself")
    func sameGateTwiceIsOneVoice() async {
        var trace = PipelineTrace()
        PreModelPipeline.reserve(.concern(.low, "passage a is stale"), for: temporal, trace: &trace)
        PreModelPipeline.reserve(.concern(.low, "passage b is stale"), for: temporal, trace: &trace)
        PreModelPipeline.reserve(.concern(.low, "passage c is stale"), for: temporal, trace: &trace)
        #expect(await pipeline().arbitrateReservations(trace: &trace) == nil)
    }

    @Test("a stage that did not run is never read as a stage that found nothing")
    func unavailableIsNotClear() async {
        var trace = PipelineTrace()
        PreModelPipeline.reserve(.unavailable("no passage carries both a subject and a date"),
                                 for: temporal, trace: &trace)
        PreModelPipeline.reserve(.concern(.moderate, "all 3 passage(s) are one source"),
                                 for: independence, trace: &trace)
        // One concern and one unreported judge. Not concurrence — and, critically, the unreported
        // judge did not count toward anything in the other direction either.
        #expect(await pipeline().arbitrateReservations(trace: &trace) == nil)
        #expect(trace.reservations.filter { $0.reading.isClear }.isEmpty)
    }

    @Test("an arbiter handed nothing rules that nothing was reported, and does not act on it")
    func noReservationsIsNotARefusal() async {
        var trace = PipelineTrace()
        // Every gate files on every path, so the four-gate pipeline cannot reach here empty. This
        // is the defensive arm for a reason enum this module does not own — `noSignals` is a real
        // ruling, and "this app's policy does not act on it" is a different statement from "this
        // cannot happen". Keeping it costs one branch; asserting it costs one test.
        #expect(await pipeline().arbitrateReservations(trace: &trace) == nil)
        if case let .noOp(reason) = trace.outcome(for: .abstentionArbiter) {
            #expect(reason.contains("no stage reported"))
        } else {
            Issue.record("expected a noOp naming the ruling the policy declined to act on")
        }
    }

    @Test("the arbiter reports even when an earlier gate already refused")
    func reportsAfterAnEarlierRefusal() async {
        var trace = PipelineTrace()
        let refusal = await pipeline().refusalBeforeSending(
            sources: [RetrievedSource(id: "a", title: "A", snippet: "x", relevancePercent: 10)],
            outbound: "",
            trace: &trace
        )
        _ = refusal
        // Whatever the four gates decided, the arbiter is never one of the stages left unreached:
        // a silently absent stage is the thing the Diagnostics screen exists to prevent.
        #expect(!trace.unreached.contains(.abstentionArbiter))
    }
}
