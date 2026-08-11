import AgentMemoryKit
import AnswerabilityKit
import ContextCompactionKit
import Foundation
import GuardrailKit
import PromptTemplateKit
import ResponseCacheKit
import RetrievalKit
import SemanticRouterKit
import Testing
@testable import AIChatApp

/// The `answerabilityGate` stage.
///
/// Driven through the real `PreModelPipeline` where the point is that the stage is wired in, and
/// called directly where the point is a specific verdict — the stage-table test only proves a case
/// exists, and a stage listed but never executed is exactly the gap this suite is for.
@Suite("Answerability gate stage")
struct AnswerabilityStageTests {
    private func pipeline() async -> PreModelPipeline {
        let prompts = PromptRegistry()
        _ = try? await prompts.register(name: "chat.system", template: "You are terse.")
        let retriever = Retriever(embedder: HashingEmbeddingProvider())
        for document in AppKnowledge.retrievalDocuments {
            try? await retriever.index(document)
        }
        return PreModelPipeline(
            prompts: prompts,
            guardrail: GuardrailPipeline(policy: GuardrailPolicy()),
            router: SemanticRouter(),
            cache: ResponseCache(capacity: 4),
            memory: MemoryStore(),
            retriever: retriever,
            compactor: ContextCompactor(strategies: [SlidingWindowCompactionStrategy()])
        )
    }

    private func source(_ id: String, _ snippet: String) -> RetrievedSource {
        RetrievedSource(id: id, title: id, snippet: snippet, relevancePercent: 80)
    }

    @Test("the stage always records an outcome, so a silent stage cannot masquerade as a wired one")
    func alwaysRecords() async throws {
        var trace = PipelineTrace()
        _ = await pipeline().prepare(userText: "what is the budget?", history: [], trace: &trace)
        #expect(trace.records.contains { $0.stage == .answerabilityGate })
    }

    @Test("a real query through the real corpus reaches the stage without breaking")
    func runsOnARealQuery() async throws {
        var trace = PipelineTrace()
        _ = await pipeline().prepare(userText: "what is the budget?", history: [], trace: &trace)
        let record = trace.records.first { $0.stage == .answerabilityGate }
        #expect(record?.outcome.isFailure == false)
    }

    /// Most turns in this app carry no passages at all. Blocking those would refuse conversation.
    @Test("no passages is a skip, not a refusal")
    func noPassagesSkips() async throws {
        var trace = PipelineTrace()
        let result = await pipeline().gateAnswerability(of: [], for: "hello there", trace: &trace)
        #expect(result == .admitted)
        guard case .skipped = trace.records.first(where: { $0.stage == .answerabilityGate })?.outcome else {
            Issue.record("expected a skip when there is no evidence to judge")
            return
        }
    }

    @Test("evidence that covers the question is admitted and recorded as having run")
    func coveredQuestionIsAdmitted() async throws {
        var trace = PipelineTrace()
        let result = await pipeline().gateAnswerability(
            of: [source("kb-ttl", "The response cache holds entries for a time-to-live of nine hundred seconds.")],
            for: "What is the time-to-live of the response cache?",
            trace: &trace
        )
        #expect(result == .admitted)
        guard case .ran = trace.records.first(where: { $0.stage == .answerabilityGate })?.outcome else {
            Issue.record("a covered question should record that the gate ran")
            return
        }
    }

    /// A coverage gap is surfaced, not refused, and this test exists to pin that decision down.
    ///
    /// `.insufficient` claims *nothing* speaks to an aspect — evidence of absence inferred from a
    /// matcher with no stemming. Wiring it as a refusal blocked "how much am I spending" against
    /// this app's own budget corpus (`spend` in the corpus, `spending` in the question), and three
    /// existing tests caught it. The gap belongs in Diagnostics where a reader can weigh it.
    @Test("a corpus that never states the fact asked is admitted, with the gap named in the trace")
    func uncoveredAttributeIsRecordedNotRefused() async throws {
        var trace = PipelineTrace()
        let result = await pipeline().gateAnswerability(
            of: [
                source("doc-agg", "The streaming aggregator buffers out-of-order chunks."),
                source("doc-drop", "The streaming aggregator drops frames once the buffer is saturated.")
            ],
            for: "When did the streaming aggregator start dropping frames?",
            trace: &trace
        )
        #expect(result == .admitted)
        guard case let .ran(detail) = trace.records.first(where: { $0.stage == .answerabilityGate })?.outcome else {
            Issue.record("the gap has to be recorded, or it is invisible to a Diagnostics reader")
            return
        }
        #expect(detail.contains("a time"), "the trace must name what was missing, not just that something was")
    }

    @Test("passages that contradict each other on the aspect asked about are refused separately")
    func contestedAspectIsRefused() async throws {
        var trace = PipelineTrace()
        let result = await pipeline().gateAnswerability(
            of: [
                source("kb-five", "The provider gateway retries a failed request up to five times."),
                source("kb-none", "The provider gateway does not retry a failed request.")
            ],
            for: "How many times does the provider gateway retry?",
            trace: &trace
        )
        guard case let .refused(refusal) = result else {
            Issue.record("expected a refusal; got \(result)")
            return
        }
        #expect(refusal.headline.contains("contradict"))
        #expect(refusal.recovery != nil)
    }

    /// Declining to rule is not a soft block. A question the gate could not read must not be
    /// refused on the strength of not having been read.
    @Test("a question the gate cannot read is admitted, recorded as a no-op rather than a refusal")
    func unreadableQuestionIsAdmittedAsNoOp() async throws {
        var trace = PipelineTrace()
        let result = await pipeline().gateAnswerability(
            of: [source("kb-ttl", "The response cache holds entries for nine hundred seconds.")],
            for: "What about it?",
            trace: &trace
        )
        #expect(result == .admitted)
        guard case .noOp = trace.records.first(where: { $0.stage == .answerabilityGate })?.outcome else {
            Issue.record("declining to rule is a no-op, not a refusal and not a skip")
            return
        }
    }

    @Test("the stage names AnswerabilityKit in Diagnostics")
    func ownsItsPackage() {
        #expect(PipelineStage.answerabilityGate.package == "AnswerabilityKit")
        #expect(!PipelineStage.answerabilityGate.title.isEmpty)
    }
}
