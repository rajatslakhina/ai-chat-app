import AgentMemoryKit
import DegenerationGuardKit
import Foundation
import GuardrailKit
import PromptTemplateKit
import ProviderGatewayKit
import ResponseCacheKit
import RetrievalKit
import SemanticRouterKit
import ContextCompactionKit
import Testing
@testable import AIChatApp

/// One SSE event carrying `content`. The content here never contains a quote or a backslash.
private func degenerationEvent(_ content: String, finish: String? = nil, usage: Bool = false) -> String {
    let reason = finish.map { "\"\($0)\"" } ?? "null"
    let tail = usage ? #","usage":{"prompt_tokens":18,"completion_tokens":900,"cost":0.0009}"# : ""
    return #"data: {"id":"gen-loop","model":"openai/gpt-4o","choices":[{"delta":{"content":""#
        + content + #""},"finish_reason":"# + reason + "}]" + tail + "}\n\n"
}

/// An answer that opens correctly, then repeats one sentence `copies` times, each in its own
/// fragment, and only reports usage on the very last event.
private func loopingStream(copies: Int = 60) -> String {
    var body = degenerationEvent("To convert km/h to m/s, divide by 3.6. ")
    for _ in 0..<copies { body += degenerationEvent("Wait, let me reconsider the units. ") }
    body += degenerationEvent("Done.", finish: "stop", usage: true)
    return body + "data: [DONE]\n\n"
}

private let cleanStream = degenerationEvent("Divide by 3.6: 3.2 km/h is ")
    + degenerationEvent("about 0.89 m/s.", finish: "stop", usage: true)
    + "data: [DONE]\n\n"

private func degenerationStub(_ body: String) -> StubURLProtocol.Stub {
    StubURLProtocol.Stub(statusCode: 200, headers: ["Content-Type": "text/event-stream"], body: Data(body.utf8))
}

private func degenerationTurn(_ text: String = "Convert 3.2 km/h to m/s") -> PreparedTurn {
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

/// Collects what reached the bubble while the answer streamed.
private final class DegenerationFragments: @unchecked Sendable {
    private let lock = NSLock()
    private var fragments: [String] = []

    func append(_ fragment: String) {
        lock.lock()
        defer { lock.unlock() }
        fragments.append(fragment)
    }

    var joined: String {
        lock.lock()
        defer { lock.unlock() }
        return fragments.joined()
    }
}

private func runDegeneration(
    _ executor: TurnExecutor,
    conversationID: String = "loop-1",
    collector: DegenerationFragments = DegenerationFragments()
) async -> (TurnResult, PipelineTrace) {
    var trace = PipelineTrace()
    let result = await executor.execute(
        degenerationTurn(),
        conversationID: conversationID,
        trace: &trace,
        onDelta: { collector.append($0) }
    )
    return (result, trace)
}

@Suite("DegenerationGuardKit - an answer that repeats itself", .serialized)
struct DegenerationGuardStageTests {
    @Test("a looping answer is cut back to one copy and the stage refuses with a way forward")
    func loopIsCut() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        StubURLProtocol.setStubs([degenerationStub(loopingStream())])
        let collector = DegenerationFragments()

        let (result, trace) = await runDegeneration(harness.executor(), collector: collector)

        guard case let .completed(completion) = result else {
            Issue.record("expected .completed, got \(result)")
            return
        }
        #expect(completion.text == "To convert km/h to m/s, divide by 3.6. Wait, let me reconsider the units.")
        guard case let .refused(refusal)? = trace.outcome(for: .degenerationGuard) else {
            Issue.record("expected a refusal, got \(String(describing: trace.outcome(for: .degenerationGuard)))")
            return
        }
        #expect(refusal.headline == "The answer started repeating itself")
        // The opening ends in ". " like every copy, so the verbatim detector sees four copies of
        // ". Wait, ... the units" two scalars before the fourth sentence ends.
        #expect(refusal.explanation.contains("the same 35-character passage 4 times in a row"))
        #expect(refusal.explanation.contains("after 177 characters"))
        #expect(refusal.explanation.contains("stopped reading after"))
        #expect(refusal.recoveryTitle == "Try again")
        #expect(trace.refusal?.stage == .degenerationGuard)
        // The executor stopped reading at the fourth copy: the closing "Done." never reached the
        // bubble. Metering is deliberately not asserted. The stub hands over the whole body at once,
        // so the provider's parser can record the usage on the last event before the cancel lands;
        // a real loop is still being generated when the cancel arrives, so its usage never comes.
        #expect(!collector.joined.contains("Done."))
        #expect(collector.joined.components(separatedBy: "reconsider").count - 1 == 4)
    }

    @Test("a clean answer is checked and passes")
    func cleanAnswerPasses() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        StubURLProtocol.setStubs([degenerationStub(cleanStream)])

        let (result, trace) = await runDegeneration(harness.executor())

        guard case let .completed(completion) = result else {
            Issue.record("expected .completed, got \(result)")
            return
        }
        #expect(completion.text == "Divide by 3.6: 3.2 km/h is about 0.89 m/s.")
        #expect(trace.outcome(for: .degenerationGuard)
            == .noOp(reason: "checked 42 character(s) over 1 model call(s); no repetition"))
        #expect(trace.refusal == nil)
    }

    /// Try again re-sends the same text in the same conversation. Without a fresh key the
    /// idempotency guard would replay the cut answer, and the button would do nothing.
    @Test("Try again after a cut answer reaches the model instead of replaying the loop")
    func retryReachesTheModel() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        StubURLProtocol.setStubs([degenerationStub(loopingStream()), degenerationStub(cleanStream)])
        let executor = harness.executor()

        _ = await runDegeneration(executor)
        let before = StubURLProtocol.requestCount
        let (result, trace) = await runDegeneration(executor)

        #expect(StubURLProtocol.requestCount == before + 1)
        guard case let .completed(completion) = result else {
            Issue.record("expected .completed, got \(result)")
            return
        }
        #expect(completion.text == "Divide by 3.6: 3.2 km/h is about 0.89 m/s.")
        #expect(trace.outcome(for: .degenerationGuard)?.summary.contains("no repetition") == true)
    }

    @Test("a replayed answer streams nothing to check")
    func replayIsRecorded() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        StubURLProtocol.setStubs([degenerationStub(cleanStream)])
        let executor = harness.executor()

        _ = await runDegeneration(executor)
        let (_, trace) = await runDegeneration(executor)

        #expect(trace.outcome(for: .idempotencyGuard)?.summary.contains("replayed") == true)
        #expect(trace.outcome(for: .degenerationGuard) == LiveDegenerationGuard.replayed)
    }

    @Test("a call that fails delivers nothing to check")
    func failureIsRecorded() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        StubURLProtocol.respond(statusCode: 429, json: OpenRouterTestFixtures.rateLimitedBody)

        let (result, trace) = await runDegeneration(harness.executor(maxAttempts: 1))

        guard case .refused = result else {
            Issue.record("expected a refusal, got \(result)")
            return
        }
        #expect(trace.outcome(for: .degenerationGuard) == LiveDegenerationGuard.discarded)
    }
}

@Suite("DegenerationGuardKit - the cut answer on screen", .serialized)
@MainActor
struct DegenerationGuardChatTests {
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

    @Test("the cut answer is delivered under a banner, and Try again asks the model again")
    func bannerAndRetry() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        StubURLProtocol.setStubs([degenerationStub(loopingStream()), degenerationStub(cleanStream)])
        let model = ChatViewModel(
            pipeline: await pipeline(),
            executor: harness.executor(),
            review: PostModelPipeline(guardrail: GuardrailPipeline(policy: GuardrailPolicy()))
        )

        model.draft = "Convert 3.2 km/h to m/s"
        model.send()
        try await settle(model) { $0.activeRefusal != nil }

        let answer = try #require(model.bubbles.last)
        #expect(answer.delivery == .delivered)
        #expect(answer.text == "To convert km/h to m/s, divide by 3.6. Wait, let me reconsider the units.")
        #expect(model.activeRefusal?.headline == "The answer started repeating itself")
        #expect(model.activeRefusal?.recoveryTitle == "Try again")

        let before = StubURLProtocol.requestCount
        model.retryLast()
        try await settle(model) { $0.bubbles.last?.text.contains("0.89") == true }

        #expect(StubURLProtocol.requestCount == before + 1, "a cut answer must not be served from the cache")
        #expect(model.activeRefusal == nil)
        #expect(model.bubbles.last?.delivery == .delivered)
    }

    private func settle(_ model: ChatViewModel, until ready: @escaping (ChatViewModel) -> Bool) async throws {
        for _ in 0..<800 {
            if !model.isSending, ready(model) { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("the turn never settled")
    }
}

@Suite("DegenerationGuardKit - outcomes in words")
struct LiveDegenerationGuardTests {
    private func finding(_ kind: LoopKind) -> DegenerationFinding {
        DegenerationFinding(kind: kind, detectedAt: 181, loopStart: 37, keepThrough: 74, sample: "x")
    }

    @Test("every kind of loop is described in words a user can read")
    func wording() {
        #expect(LiveDegenerationGuard.repeated(.verbatim(period: 35, copies: 4))
            == "the same 35-character passage 4 times in a row")
        #expect(LiveDegenerationGuard.repeated(.unitCycle(units: 1, copies: 4)) == "the same sentence 4 times in a row")
        #expect(LiveDegenerationGuard.repeated(.unitCycle(units: 3, copies: 4)) == "the same 3 sentences 4 times in a row")
        #expect(LiveDegenerationGuard.repeated(.custom("cap")) == "a repeating pattern (cap)")
        let refusal = LiveDegenerationGuard.refusal(for: finding(.verbatim(period: 35, copies: 4)))
        #expect(refusal.stage == .degenerationGuard)
        #expect(refusal.explanation.contains("after 181 characters"))
    }

    @Test("a summary keeps the first finding across model calls")
    func summaryKeepsFirstFinding() {
        var looping = DegenerationMonitor()
        looping.ingest(String(repeating: "Retrying the same request. ", count: 6))
        var clean = DegenerationMonitor()
        clean.ingest("A short clean answer.")
        var summary = LiveDegenerationGuard.Summary()
        summary.absorb(looping)
        summary.absorb(clean)
        #expect(summary.calls == 2)
        #expect(summary.scanned == looping.scanned + 21)
        #expect(summary.finding == looping.finding)
        #expect(summary.finding != nil)
        guard case .refused = LiveDegenerationGuard.outcome(summary) else {
            Issue.record("a finding must refuse")
            return
        }
        #expect(PipelineStage.degenerationGuard.package == "DegenerationGuardKit")
    }
}
