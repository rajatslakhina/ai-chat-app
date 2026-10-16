import AgentMemoryKit
import AnswerContinuationKit
import ContextCompactionKit
import Foundation
import GuardrailKit
import PromptTemplateKit
import ProviderGatewayKit
import ResponseCacheKit
import RetrievalKit
import SemanticRouterKit
import Testing
@testable import AIChatApp

/// One SSE event carrying `content`, JSON-escaped, with an optional finish reason and usage.
private func cutEvent(
    _ content: String,
    finish: String? = nil,
    prompt: Int = 18,
    completion: Int = 0,
    cost: String? = nil
) -> String {
    let escaped = content.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    let reason = finish.map { "\"\($0)\"" } ?? "null"
    let usage = finish == nil ? ""
        : #","usage":{"prompt_tokens":"# + "\(prompt)" + #","completion_tokens":"# + "\(completion)"
            + (cost.map { #","cost":"# + $0 } ?? "") + "}"
    return #"data: {"id":"gen-cut","model":"openai/gpt-4o","choices":[{"delta":{"content":""#
        + escaped + #""},"finish_reason":"# + reason + "}]" + usage + "}\n\n"
}

/// A reply in two fragments that ends with `finish`.
private func cutStream(
    _ first: String,
    _ second: String,
    finish: String,
    prompt: Int,
    completion: Int,
    cost: String? = nil
) -> String {
    cutEvent(first) + cutEvent(second, finish: finish, prompt: prompt, completion: completion, cost: cost)
        + "data: [DONE]\n\n"
}

private func cutStub(_ body: String) -> StubURLProtocol.Stub {
    StubURLProtocol.Stub(statusCode: 200, headers: ["Content-Type": "text/event-stream"], body: Data(body.utf8))
}

/// The dose answer, cut inside "1,500".
private let doseCut = cutStream("The usual adult dose ", "is 1,5", finish: "length", prompt: 18, completion: 1_024)
/// The continuation: repeats "dose is", then finishes.
private let doseRest = cutStream("dose is 1,500 mg ", "per day.", finish: "stop", prompt: 40, completion: 9)
/// A continuation that is cut again, inside "doses".
private let doseRestCut = cutStream("dose is 1,500 mg per day, ", "split into three do", finish: "length", prompt: 40, completion: 1_024)

private func cutTurn(_ text: String = "What is the usual adult dose?") -> PreparedTurn {
    PreparedTurn(
        modelID: "openai/gpt-4o",
        messages: [LLMMessage(role: .system, content: "You are terse."), LLMMessage(role: .user, content: text)],
        outboundUserText: text,
        displayUserText: text,
        sources: [],
        didCompact: false,
        estimatedInputTokens: 20
    )
}

private func runCut(_ executor: TurnExecutor, conversationID: String = "cut-1") async -> (TurnResult, PipelineTrace) {
    var trace = PipelineTrace()
    let result = await executor.execute(cutTurn(), conversationID: conversationID, trace: &trace, onDelta: { _ in })
    return (result, trace)
}

private func body(_ index: Int) -> String {
    let bodies = StubURLProtocol.allBodies
    return index < bodies.count ? String(decoding: bodies[index], as: UTF8.self) : ""
}

@Suite("AnswerContinuationKit - an answer the length limit cut", .serialized)
struct AnswerContinuationStageTests {
    @Test("a cut answer is finished with one more call, stitched, and both calls are metered")
    func cutIsContinued() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        StubURLProtocol.setStubs([cutStub(doseCut), cutStub(doseRest)])

        let (result, trace) = await runCut(harness.executor())

        guard case let .completed(completion) = result else {
            Issue.record("expected .completed, got \(result)")
            return
        }
        #expect(completion.text == "The usual adult dose is 1,500 mg per day.")
        #expect(StubURLProtocol.requestCount == 2)
        let detail = trace.outcome(for: .answerContinuation)?.summary ?? ""
        #expect(detail.contains("cut at the 1024-token limit after 27 characters"), "\(detail)")
        #expect(detail.contains("+18 characters; removed repeated text"), "\(detail)")
        #expect(trace.refusal == nil)
        // The continuation request carries the kept answer and the instruction, and no tools.
        let second = body(1)
        #expect(second.contains("The usual adult dose is\""))
        #expect(second.contains("Your previous reply was cut off by the output limit"))
        #expect(!second.contains("\"tools\""))
        // Both calls were billed, so both are metered.
        #expect(completion.promptTokens == 58)
        #expect(completion.completionTokens == 1_033)
        #expect(trace.outcome(for: .metering)?.summary
            == "58 in / 1033 out (the cut answer and its continuation)")
    }

    @Test("the cost OpenRouter reports for both calls is added up")
    func reportedCostsAreSummed() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        StubURLProtocol.setStubs([
            cutStub(cutStream("The usual adult dose ", "is 1,5", finish: "length", prompt: 18, completion: 1_024, cost: "0.0011")),
            cutStub(cutStream("dose is 1,500 mg ", "per day.", finish: "stop", prompt: 40, completion: 9, cost: "0.0002"))
        ])

        let (result, _) = await runCut(harness.executor())

        guard case let .completed(completion) = result else {
            Issue.record("expected .completed, got \(result)")
            return
        }
        #expect(abs((completion.reportedCostUSD ?? 0) - 0.0013) < 0.000_000_1)
    }

    @Test("still cut after one more call: the safe part is delivered under a refusal")
    func stillCutIsRefused() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        StubURLProtocol.setStubs([cutStub(doseCut), cutStub(doseRestCut)])

        let (result, trace) = await runCut(harness.executor())

        guard case let .completed(completion) = result else {
            Issue.record("expected .completed, got \(result)")
            return
        }
        #expect(completion.text == "The usual adult dose is 1,500 mg per day, split into three")
        #expect(StubURLProtocol.requestCount == 2, "one continuation round, never more")
        guard case let .refused(refusal)? = trace.outcome(for: .answerContinuation) else {
            Issue.record("expected a refusal, got \(String(describing: trace.outcome(for: .answerContinuation)))")
            return
        }
        #expect(refusal.headline == "The answer was cut off at the length limit")
        #expect(refusal.explanation.contains("all 1024 output tokens after 27 characters"))
        #expect(refusal.explanation.contains("asking once more for the rest was cut off too"))
        #expect(refusal.explanation.contains("A lower Effort"))
        #expect(refusal.recoveryTitle == "Try again")
        #expect(trace.refusal?.stage == .answerContinuation)
    }

    @Test("a cut code block whose continuation fails is closed, and the turn is not resent")
    func failedContinuationClosesTheBlock() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        let codeCut = cutStream("Here:\n\n```swift\n", "let total = items.redu", finish: "length", prompt: 18, completion: 1_024)
        StubURLProtocol.setStubs([
            cutStub(codeCut),
            StubURLProtocol.Stub(statusCode: 500, headers: [:], body: Data(#"{"error":{"message":"boom"}}"#.utf8))
        ])

        let (result, trace) = await runCut(harness.executor())

        guard case let .completed(completion) = result else {
            Issue.record("expected .completed, got \(result)")
            return
        }
        #expect(completion.text == "Here:\n\n```swift\nlet total =\n```")
        #expect(StubURLProtocol.requestCount == 2, "the billed answer is not bought again by the retry policy")
        guard case let .refused(refusal)? = trace.outcome(for: .answerContinuation) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(refusal.explanation.contains("asking for the rest failed"))
        #expect(refusal.explanation.contains("with its code block closed"))
        #expect(trace.outcome(for: .metering)?.summary == "18 in / 1024 out (the cut answer and its continuation)")
    }

    @Test("an answer the model finished is checked and passes")
    func finishedAnswerPasses() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        StubURLProtocol.setStubs([cutStub(doseRest)])

        let (_, trace) = await runCut(harness.executor())

        #expect(trace.outcome(for: .answerContinuation) == .noOp(reason: "the model stopped on its own (finished)"))
        #expect(StubURLProtocol.requestCount == 1)
        #expect(trace.outcome(for: .metering)?.summary == "40 in / 9 out")
    }

    @Test("Try again after a cut answer reaches the model instead of replaying it")
    func retryReachesTheModel() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        StubURLProtocol.setStubs([cutStub(doseCut), cutStub(doseRestCut), cutStub(doseRest)])
        let executor = harness.executor()

        _ = await runCut(executor)
        let before = StubURLProtocol.requestCount
        let (result, trace) = await runCut(executor)

        #expect(StubURLProtocol.requestCount == before + 1)
        guard case let .completed(completion) = result else {
            Issue.record("expected .completed, got \(result)")
            return
        }
        #expect(completion.text == "dose is 1,500 mg per day.")
        #expect(trace.outcome(for: .answerContinuation) == .noOp(reason: "the model stopped on its own (finished)"))
    }

    @Test("a replayed answer and a failed call are recorded without a check")
    func replayAndFailure() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        StubURLProtocol.setStubs([cutStub(doseRest)])
        let executor = harness.executor()
        _ = await runCut(executor)
        let (_, replay) = await runCut(executor)
        #expect(replay.outcome(for: .answerContinuation) == LiveAnswerContinuation.replayed)

        let other = ExecutorHarness()
        try await other.registerScopes()
        StubURLProtocol.respond(statusCode: 429, json: OpenRouterTestFixtures.rateLimitedBody)
        let (_, failed) = await runCut(other.executor(maxAttempts: 1), conversationID: "cut-2")
        #expect(failed.outcome(for: .answerContinuation) == LiveAnswerContinuation.discarded)
    }
}

@Suite("AnswerContinuationKit - the continued answer on screen", .serialized)
@MainActor
struct AnswerContinuationChatTests {
    private func pipeline() async -> PreModelPipeline {
        let prompts = PromptRegistry()
        _ = try? await prompts.register(name: "chat.system", template: "You are terse.")
        return PreModelPipeline(
            prompts: prompts,
            guardrail: GuardrailPipeline(policy: GuardrailPolicy()),
            router: SemanticRouter(),
            cache: ResponseCache(capacity: 8),
            memory: MemoryStore(),
            retriever: Retriever(embedder: HashingEmbeddingProvider()),
            compactor: ContextCompactor(strategies: [SlidingWindowCompactionStrategy()])
        )
    }

    @Test("the bubble that streamed the cut answer ends with the stitched one")
    func bubbleIsReplaced() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        StubURLProtocol.setStubs([cutStub(doseCut), cutStub(doseRest)])
        let model = ChatViewModel(
            pipeline: await pipeline(),
            executor: harness.executor(),
            review: PostModelPipeline(guardrail: GuardrailPipeline(policy: GuardrailPolicy()))
        )

        model.draft = "What is the usual adult dose?"
        model.send()
        for _ in 0..<800 {
            if !model.isSending, model.bubbles.last?.delivery == .delivered { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        #expect(model.bubbles.last?.text == "The usual adult dose is 1,500 mg per day.")
        #expect(model.activeRefusal == nil)
    }
}

@Suite("AnswerContinuationKit - outcomes in words")
struct LiveAnswerContinuationTests {
    @Test("every status and stop reason is described in words a user can read")
    func wording() {
        #expect(LiveAnswerContinuation.why(.notNeeded(.finished)) == "asking for the rest finished it")
        #expect(LiveAnswerContinuation.why(.completed(rounds: 1)) == "asking for the rest finished it")
        #expect(LiveAnswerContinuation.why(.incomplete(.continuationDisabled)) == "continuing is turned off")
        #expect(LiveAnswerContinuation.why(.incomplete(.noProgress)) == "asking for the rest added nothing new")
        #expect(LiveAnswerContinuation.why(.incomplete(.restarted))
            == "asking for the rest started the answer over instead")
        #expect(LiveAnswerContinuation.why(.incomplete(.stoppedBy(.contentFilter)))
            == "asking for the rest stopped for another reason (contentFilter)")
        #expect(LiveAnswerContinuation.describe(LLMResponse.FinishReason.maxTokens) == "length limit")
        #expect(LiveAnswerContinuation.describe(LLMResponse.FinishReason.toolCallLimitExceeded) == "tool-call limit")
        #expect(LiveAnswerContinuation.describe(StitchRemoval.preamble("x")) == "a preamble")
        #expect(LiveAnswerContinuation.describe(StitchRemoval.reopenedFence("x")) == "a reopened code fence")
        #expect(LiveAnswerContinuation.stop(.toolCallLimitExceeded) == .toolCall)
        #expect(LiveAnswerContinuation.message(ContinuationMessage(role: .user, content: "go")).role == .user)
    }

    @Test("outcomes without a cut, and whether a call was made")
    func outcomes() {
        #expect(LiveAnswerContinuation.outcome(.none, limit: 1_024).summary.contains("no stop reason reached the app"))
        #expect(LiveAnswerContinuation.outcome(.stopped(.toolCallLimitExceeded), limit: 1_024)
            == .noOp(reason: "the model stopped on its own (tool-call limit)"))
        #expect(LiveAnswerContinuation.madeACall(.ran(detail: "x")))
        #expect(!LiveAnswerContinuation.madeACall(.noOp(reason: "x")))
        #expect(!LiveAnswerContinuation.madeACall(nil))
        #expect(PipelineStage.answerContinuation.package == "AnswerContinuationKit")
        #expect(LiveAnswerContinuation.policy.maxRounds == 1)
    }
}
