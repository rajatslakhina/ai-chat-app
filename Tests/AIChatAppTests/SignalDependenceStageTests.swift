import AbstentionPolicyKit
import AgentMemoryKit
import ContextCompactionKit
import Foundation
import GuardrailKit
import PromptTemplateKit
import ResponseCacheKit
import RetrievalKit
import SemanticRouterKit
import SignalDependenceKit
import Testing
@testable import AIChatApp

/// The stage that asks how many of the four gates before it are separate judges.
@Suite("Signal dependence stage")
struct SignalDependenceStageTests {
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

    @Test("a turn where no gate filed anything is skipped, not silently passed over")
    func nothingFiled() async {
        var trace = PipelineTrace()
        await pipeline().deflateSignalDependence(trace: &trace)
        if case let .skipped(reason) = trace.outcome(for: .signalDependence) {
            #expect(reason.contains("no gate filed"))
        } else {
            Issue.record("expected the stage to record why it had nothing to do")
        }
    }

    @Test("two unrelated gates are left alone, and the stage says so")
    func nothingToMerge() async {
        var trace = PipelineTrace()
        PreModelPipeline.reserve(.concern(.low, "thin"), for: answerability, trace: &trace)
        PreModelPipeline.reserve(.concern(.low, "merged"), for: independence, trace: &trace)
        await pipeline().deflateSignalDependence(trace: &trace)
        #expect(trace.reservations.count == 2)
        if case let .noOp(reason) = trace.outcome(for: .signalDependence) {
            #expect(reason.contains("2 independent voices"))
        } else {
            Issue.record("expected a no-op naming the voice count")
        }
    }

    @Test("stability cannot corroborate the gate it was computed from")
    func derivedGateMerges() async {
        var trace = PipelineTrace()
        PreModelPipeline.reserve(.concern(.moderate, "coverage gap"), for: answerability, trace: &trace)
        PreModelPipeline.reserve(.concern(.moderate, "offsetting weakness"), for: stability, trace: &trace)

        // Before: two origins, which is exactly the app's concurrence threshold.
        #expect(PreModelPipeline.abstentionArbiter.rule(on: trace.reservations).isAbstention)

        await pipeline().deflateSignalDependence(trace: &trace)
        #expect(trace.reservations.count == 1)
        // The upstream judge survives, because it is the one that observed anything directly.
        #expect(trace.reservations[0].origin == answerability)
        #expect(!PreModelPipeline.abstentionArbiter.rule(on: trace.reservations).isAbstention)
    }

    @Test("two readings of one corpus are one corpus's opinion")
    func sharedCorpusMerges() async {
        var trace = PipelineTrace()
        PreModelPipeline.reserve(.concern(.low, "one passage merged"), for: independence, trace: &trace)
        PreModelPipeline.reserve(.concern(.low, "one passage stale"), for: temporal, trace: &trace)
        await pipeline().deflateSignalDependence(trace: &trace)
        #expect(trace.reservations.count == 1)
        if case let .ran(detail) = trace.outcome(for: .signalDependence) {
            #expect(detail.contains("2 gates read as 1 voice(s)"))
            #expect(detail.contains("shared input"))
            #expect(detail.contains("1 concurring voice(s)"))
        } else {
            Issue.record("expected the stage to report what it merged")
        }
    }

    @Test("four gates, two genuinely separate voices, and the turn still stops")
    func fourGatesTwoVoices() async {
        var trace = PipelineTrace()
        PreModelPipeline.reserve(.concern(.moderate, "coverage gap"), for: answerability, trace: &trace)
        PreModelPipeline.reserve(.concern(.low, "offsetting weakness"), for: stability, trace: &trace)
        PreModelPipeline.reserve(.concern(.low, "one passage merged"), for: independence, trace: &trace)
        PreModelPipeline.reserve(.concern(.low, "one passage stale"), for: temporal, trace: &trace)

        await pipeline().deflateSignalDependence(trace: &trace)
        #expect(trace.reservations.count == 2)
        // Two voices still concur, so the refusal survives — on a count that means something.
        let refusal = await pipeline().arbitrateReservations(trace: &trace)
        #expect(refusal != nil)
        #expect(refusal?.headline == "Several checks were uneasy about this answer")
    }

    @Test("a refusal is never merged away by something it is entangled with")
    func refusalSurvives() async {
        var trace = PipelineTrace()
        PreModelPipeline.reserve(.refuse("nothing covers the question"), for: answerability, trace: &trace)
        PreModelPipeline.reserve(.concern(.low, "offsetting weakness"), for: stability, trace: &trace)
        await pipeline().deflateSignalDependence(trace: &trace)
        #expect(trace.reservations.contains { $0.origin == answerability && $0.reading.isRefusal })
    }

    @Test("the declared graph states only what is true by construction")
    func graphIsMinimal() {
        let graph = PreModelPipeline.dependenceGraph
        #expect(graph.edges.count == 2)
        let derived = DependenceOrigin(PreModelPipeline.ReservationOrigin.stability.rawValue)
        let upstream = DependenceOrigin(PreModelPipeline.ReservationOrigin.answerability.rawValue)
        #expect(graph.strength(between: derived, and: upstream) == 1)
        #expect(graph.mechanisms(between: derived, and: upstream) == [.derived])
        // Nothing links the gate to the corpus readers; a guessed edge here loosens the arbiter.
        let corpus = DependenceOrigin(PreModelPipeline.ReservationOrigin.independence.rawValue)
        #expect(graph.strength(between: upstream, and: corpus) == 0)
    }
}
