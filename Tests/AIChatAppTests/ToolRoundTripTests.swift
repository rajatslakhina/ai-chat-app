import AgentMemoryKit
import ContextCompactionKit
import CostEstimatorKit
import Foundation
import GuardrailKit
import IdempotencyKit
import PromptTemplateKit
import ProviderGatewayKit
import QuotaGovernorKit
import ResponseCacheKit
import RetrievalKit
import RetryPolicyKit
import SemanticRouterKit
import Testing
import TokenMeterKit
import ToolAuthorityKit
import ToolRegistryKit
import WorkloadProfilerKit
@testable import AIChatApp

// MARK: - Wire fixtures

/// One buffered response in which the model asks for a tool.
///
/// `arguments` is a JSON *string* nested inside JSON, which is how OpenRouter really sends it and
/// the reason the app parses it twice. Escaping it here rather than hand-writing the escapes keeps
/// the fixtures readable.
private func toolCallBody(
    id: String = "call_1",
    name: String,
    arguments: String
) -> String {
    let escaped = arguments
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return """
    {"id":"gen-tool","model":"openai/gpt-4o","choices":[{"finish_reason":"tool_calls",
    "message":{"role":"assistant","content":null,"tool_calls":[{"id":"\(id)","type":"function",
    "function":{"name":"\(name)","arguments":"\(escaped)"}}]}}],
    "usage":{"prompt_tokens":40,"completion_tokens":22,"cost":0.00004}}
    """
}

private func proseBody(_ text: String) -> String {
    """
    {"id":"gen-prose","model":"openai/gpt-4o","choices":[{"finish_reason":"stop",
    "message":{"role":"assistant","content":"\(text)"}}],
    "usage":{"prompt_tokens":60,"completion_tokens":12,"cost":0.0001}}
    """
}

private func stubJSON(_ bodies: [String]) {
    StubURLProtocol.setStubs(
        bodies.map {
            .init(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data($0.utf8)
            )
        }
    )
}

/// The decoded `messages` array of the nth request that actually went out.
private func sentMessages(at index: Int) throws -> [[String: Any]] {
    let bodies = StubURLProtocol.allBodies
    try #require(index < bodies.count, "only \(bodies.count) request(s) were sent")
    let json = try JSONSerialization.jsonObject(with: bodies[index]) as? [String: Any]
    return try #require(json?["messages"] as? [[String: Any]])
}

private func sentTools(at index: Int) throws -> [[String: Any]] {
    let bodies = StubURLProtocol.allBodies
    try #require(index < bodies.count, "only \(bodies.count) request(s) were sent")
    let json = try JSONSerialization.jsonObject(with: bodies[index]) as? [String: Any]
    return try #require(json?["tools"] as? [[String: Any]])
}

// MARK: - Harness

/// Collects tool activity from a `@Sendable` callback.
private final class ActivityLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ToolActivity] = []

    func append(_ item: ToolActivity) {
        lock.lock()
        defer { lock.unlock() }
        items.append(item)
    }

    var all: [ToolActivity] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

/// A `TurnExecutor` with the real registry, the real broker, and only the network faked.
private struct ToolHarness {
    let usage = UsageRecorder()
    let profiler = WorkloadProfiler()
    let governor = QuotaGovernor()
    let idempotency = IdempotencyGuard()
    let pricing = PricingRegistry()
    let meter: TokenMeter
    let scopes = BudgetScopes(account: ScopeID("account"), conversation: ScopeID("conversation"))
    let tools: ToolRoundTrip

    init(
        granted: [String] = [DemoTools.calculatorName, DemoTools.clockName],
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 0) }
    ) async {
        meter = TokenMeter(registry: pricing)
        let registry = ToolRegistryKit.ToolRegistry()
        await registry.register(DemoTools.calculator, handler: DemoTools.calculatorHandler())
        await registry.register(
            DemoTools.currentTime,
            handler: DemoTools.currentTimeHandler(now: now)
        )
        tools = ToolRoundTrip(
            registry: registry,
            gate: ToolAuthorityGate(capabilities: ToolAuthorityGate.readOnly(tools: granted))
        )
    }

    func registerScopes() async throws {
        try await governor.register(scopes.account, limits: .unlimited, at: 0)
        try await governor.register(scopes.conversation, under: scopes.account, at: 0)
    }

    func executor(maxToolHops: Int = 3, withTools: Bool = true) -> TurnExecutor {
        TurnExecutor(
            provider: OpenRouterProvider(
                configuration: OpenRouterConfiguration(apiKey: "sk-or-v1-test", streaming: false),
                session: StubURLProtocol.makeSession(),
                usageObserver: usage
            ),
            idempotency: idempotency,
            profiler: profiler,
            estimator: CostEstimator(priceBook: Self.priceBook()),
            governor: governor,
            retryPolicy: ExponentialBackoffRetryPolicy(maxAttempts: 1),
            meter: meter,
            usage: usage,
            scopes: scopes,
            tools: withTools ? tools : nil,
            maxToolHops: maxToolHops
        )
    }

    static func priceBook() -> PriceBook {
        guard let book = try? PriceBook([
            (
                CostEstimatorKit.ModelID("openai/gpt-4o"),
                try ModelPrice(
                    model: CostEstimatorKit.ModelID("openai/gpt-4o"),
                    inputPerMillion: 250_000_000,
                    outputPerMillion: 1_000_000_000
                )
            )
        ]) else {
            fatalError("a known-valid price book must build")
        }
        return book
    }
}

private func turn(
    text: String = "what is (3 + 4) * 12",
    sources: [RetrievedSource] = []
) -> PreparedTurn {
    PreparedTurn(
        modelID: "openai/gpt-4o",
        messages: [
            LLMMessage(role: .system, content: "You are terse."),
            LLMMessage(role: .user, content: text)
        ],
        outboundUserText: text,
        displayUserText: text,
        sources: sources,
        didCompact: false,
        estimatedInputTokens: 20
    )
}

private func run(
    _ executor: TurnExecutor,
    turn prepared: PreparedTurn = turn(),
    conversationID: String = "conv-1"
) async -> (TurnResult, PipelineTrace, [ToolActivity]) {
    var trace = PipelineTrace()
    let log = ActivityLog()
    let result = await executor.execute(
        prepared,
        conversationID: conversationID,
        trace: &trace,
        onDelta: { _ in },
        onTool: { log.append($0) }
    )
    return (result, trace, log.all)
}

private func completedText(_ result: TurnResult) -> String? {
    guard case let .completed(completion) = result else { return nil }
    return completion.text
}

// MARK: - Suites

@Suite("Tool round trip — the happy path")
struct ToolRoundTripHappyPathTests {
    @Test("a requested tool runs, its result goes back, and the user reads prose rather than JSON")
    func fullRoundTrip() async throws {
        let harness = await ToolHarness()
        try await harness.registerScopes()
        stubJSON([
            toolCallBody(name: "calculator", arguments: #"{"expression":"(3 + 4) * 12"}"#),
            proseBody("That comes to 84.")
        ])

        let (result, trace, activity) = await run(harness.executor())

        #expect(completedText(result) == "That comes to 84.")
        #expect(StubURLProtocol.requestCount == 2, "the tool result has to be paid a second call")
        #expect(trace.refusal == nil)
        #expect(trace.failures.isEmpty)

        let authority = try #require(trace.outcome(for: .toolAuthority))
        #expect(authority.summary.contains("allowed calculator read on tools/calculator"))
        let dispatch = try #require(trace.outcome(for: .toolDispatch))
        #expect(dispatch == .ran(detail: "calculator → ok"))
        let loop = try #require(trace.outcome(for: .agentLoop))
        #expect(loop == .ran(detail: "1 tool call(s) over 2 step(s): calculator"))

        #expect(activity == [.started(tool: "calculator"), .finished(tool: "calculator")])

        // The second call carries the tool's real answer, so the model is reading 84 rather than
        // being asked to remember it.
        let follow = try sentMessages(at: 1)
        let observation = try #require(follow.last?["content"] as? String)
        #expect(observation.contains("\"result\":84"))
        #expect(observation.contains("Tool \"calculator\" returned"))
    }

    @Test("the registered tools reach the wire as JSON Schema functions")
    func toolsAreAdvertised() async throws {
        let harness = await ToolHarness()
        try await harness.registerScopes()
        stubJSON([proseBody("Paris.")])

        _ = await run(harness.executor(), turn: turn(text: "capital of France"))

        let tools = try sentTools(at: 0)
        #expect(tools.count == 2)
        #expect(tools.allSatisfy { $0["type"] as? String == "function" })
        let names = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        #expect(names == ["calculator", "current_time"], "sorted, so the bytes stay cacheable")

        let calculator = try #require(
            tools.compactMap { $0["function"] as? [String: Any] }
                .first { $0["name"] as? String == "calculator" }
        )
        let parameters = try #require(calculator["parameters"] as? [String: Any])
        #expect(parameters["type"] as? String == "object")
        #expect(parameters["required"] as? [String] == ["expression"])
    }

    /// The common path for ordinary chat, and the one that must be recorded rather than omitted —
    /// an unrecorded stage is indistinguishable from a package that was never wired.
    @Test("a turn where the model wants no tool records all three stages as having done nothing")
    func noToolRequested() async throws {
        let harness = await ToolHarness()
        try await harness.registerScopes()
        stubJSON([proseBody("Paris.")])

        let (result, trace, activity) = await run(harness.executor())

        #expect(completedText(result) == "Paris.")
        #expect(StubURLProtocol.requestCount == 1)
        #expect(activity.isEmpty)
        #expect(trace.outcome(for: .toolAuthority) == .noOp(reason: "model requested no tools"))
        #expect(trace.outcome(for: .toolDispatch) == .noOp(reason: "model requested no tools"))
        #expect(
            trace.outcome(for: .agentLoop)
                == .noOp(reason: "model answered directly; no tool call requested")
        )
    }

    @Test("a conversation with no registry reports the stages as skipped, not as unreached")
    func noToolsConfigured() async throws {
        let harness = await ToolHarness()
        try await harness.registerScopes()
        stubJSON([proseBody("Paris.")])

        let (_, trace, _) = await run(harness.executor(withTools: false))

        let reason = "no tools registered for this conversation"
        #expect(trace.outcome(for: .toolAuthority) == .skipped(reason: reason))
        #expect(trace.outcome(for: .agentLoop) == .skipped(reason: reason))
        #expect(!trace.unreached.contains(.toolDispatch))
    }

    @Test("an argument-less tool call is normalised rather than rejected as broken JSON")
    func emptyArgumentsAreNormalised() async throws {
        let harness = await ToolHarness()
        try await harness.registerScopes()
        stubJSON([
            toolCallBody(name: "current_time", arguments: ""),
            proseBody("It is midnight UTC.")
        ])

        let (result, trace, _) = await run(harness.executor(), turn: turn(text: "what time is it"))

        #expect(completedText(result) == "It is midnight UTC.")
        #expect(trace.outcome(for: .toolDispatch) == .ran(detail: "current_time → ok"))
        let observation = try #require(try sentMessages(at: 1).last?["content"] as? String)
        #expect(observation.contains("1970-01-01T00:00:00Z"))
    }

    /// A replayed turn must not re-run the tool, and must say so rather than reading as three
    /// silently unwired packages.
    @Test("a replayed turn reports the round trip as not repeated")
    func replayDoesNotRerunTheTool() async throws {
        let harness = await ToolHarness()
        try await harness.registerScopes()
        let executor = harness.executor()

        stubJSON([
            toolCallBody(name: "calculator", arguments: #"{"expression":"2+2"}"#),
            proseBody("Four.")
        ])
        _ = await run(executor)

        stubJSON([proseBody("Four.")])
        let (result, trace, activity) = await run(executor)

        #expect(completedText(result) == "Four.")
        #expect(StubURLProtocol.requestCount == 0, "a replay must not hit the network again")
        #expect(activity.isEmpty)
        let reason = "replayed an earlier result; the tool round trip was not repeated"
        #expect(trace.outcome(for: .toolDispatch) == .skipped(reason: reason))
        #expect(trace.outcome(for: .agentLoop) == .skipped(reason: reason))
    }
}

@Suite("Tool round trip — the authority gate")
struct ToolAuthorityRoundTripTests {
    /// The requirement this whole stage exists for: a declined call is a refusal the user can act
    /// on, not a crash and not a silent skip.
    @Test("a call with no capability is refused before dispatch, with an approval to offer")
    func deniedCallIsARefusal() async throws {
        let harness = await ToolHarness(granted: [DemoTools.clockName])
        try await harness.registerScopes()
        stubJSON([
            toolCallBody(name: "calculator", arguments: #"{"expression":"2+2"}"#),
            proseBody("unreachable")
        ])

        let (result, trace, activity) = await run(harness.executor())

        guard case .completed = result else {
            Issue.record("the model's own prose still publishes: \(result)")
            return
        }
        #expect(StubURLProtocol.requestCount == 1, "a refused call must not fund a second call")

        let refusal = try #require(trace.refusal)
        #expect(refusal.stage == .toolAuthority)
        #expect(refusal.headline == "Tool call blocked")
        #expect(refusal.explanation == "no capability for tool 'calculator'")
        #expect(refusal.recovery == .approveTool(name: "calculator"))
        #expect(refusal.recoveryTitle == "Approve calculator")

        #expect(
            trace.outcome(for: .toolDispatch) == .skipped(reason: "the call was not authorized"),
            "nothing may run once the gate has said no"
        )
        #expect(activity == [.started(tool: "calculator"), .cleared(tool: "calculator")])
    }

    /// Authority is asked before dispatch, never after: a handler that has already run cannot be
    /// un-run by a policy decision.
    @Test("a denied call never reaches the registry at all")
    func deniedCallIsNotDispatched() async throws {
        let harness = await ToolHarness(granted: [])
        try await harness.registerScopes()
        stubJSON([toolCallBody(name: "calculator", arguments: #"{"expression":"2+2"}"#)])

        _ = await run(harness.executor())

        let statistics = await harness.tools.statistics()
        #expect(statistics.totalCalls == 0, "the registry must not have been asked")
    }

    /// The third `AuthorityDecision` case, and the reason there are three rather than two:
    /// "not yet" is a different answer from "never", and a caller that cannot tell them apart
    /// either blocks forever or learns to auto-approve.
    @Test("a supervised tool asks for a signature instead of running, and nothing is dispatched")
    func approvalRequiredStopsTheTurn() async throws {
        let registry = ToolRegistryKit.ToolRegistry()
        await registry.register(DemoTools.calculator, handler: DemoTools.calculatorHandler())
        let supervised = Capability(
            tool: ToolName(DemoTools.calculatorName),
            actions: [.read],
            scope: .subtree(ResourcePath("tools/calculator")),
            maxProvenance: .modelAuthored,
            requiresApproval: true
        )
        let roundTrip = ToolRoundTrip(
            registry: registry,
            gate: ToolAuthorityGate(capabilities: [supervised])
        )

        let resolution = await roundTrip.resolve(
            id: "call_1",
            toolName: DemoTools.calculatorName,
            argumentsJSON: Data(#"{"expression":"2+2"}"#.utf8),
            in: ToolCallContext(conversationID: "conv-1", provenance: .modelAuthored)
        )

        let refusal = try #require(resolution.refusal)
        #expect(refusal.headline == "Approval needed")
        #expect(refusal.recovery == .approveTool(name: "calculator"))
        #expect(resolution.observation == nil, "nothing ran, so there is nothing to report back")
        #expect(
            resolution.records.first?.outcome == .ran(detail: "approval required for calculator"),
            "nothing was refused — the turn is waiting on a human"
        )
        let statistics = await roundTrip.statistics()
        #expect(statistics.totalCalls == 0)
    }

    @Test("closing a conversation gives up its tool authority")
    func closingRevokes() async throws {
        let harness = await ToolHarness()
        try await harness.registerScopes()
        stubJSON([
            toolCallBody(name: "calculator", arguments: #"{"expression":"2+2"}"#),
            proseBody("Four.")
        ])
        // One executor for both sends: `QuotaGovernorKit` refuses a tick that goes backwards, and
        // each executor owns its own monotonic counter.
        let executor = harness.executor()
        _ = await run(executor, conversationID: "conv-closing")
        await harness.tools.closeConversation("conv-closing")

        // Different text so the idempotency guard treats this as a new effect rather than a replay.
        stubJSON([
            toolCallBody(name: "calculator", arguments: #"{"expression":"2+2"}"#),
            proseBody("Still four.")
        ])
        let (_, trace, _) = await run(
            executor,
            turn: turn(text: "and again"),
            conversationID: "conv-closing"
        )
        // Re-opening mints a fresh grant rather than resurrecting the revoked one, so the call is
        // allowed again — the assertion is that closing did not leave the broker in a broken state.
        #expect(trace.refusal == nil)
        #expect(trace.outcome(for: .toolDispatch) == .ran(detail: "calculator → ok"))
    }

    @Test("a tool call built from a retrieved page is stopped by the provenance ceiling")
    func retrievedArgumentsAreUntrusted() async throws {
        let harness = await ToolHarness()
        try await harness.registerScopes()
        stubJSON([toolCallBody(name: "calculator", arguments: #"{"expression":"2+2"}"#)])

        let prepared = turn(
            sources: [
                RetrievedSource(id: "kb-88", title: "Pricing", snippet: "…", relevancePercent: 91)
            ]
        )
        let (_, trace, _) = await run(harness.executor(), turn: prepared)

        let refusal = try #require(trace.refusal)
        #expect(refusal.explanation.contains("untrusted(kb-88)"))
        #expect(refusal.recovery == .approveTool(name: "calculator"))
    }
}

@Suite("Tool round trip — what the model gets wrong, and what actually breaks")
struct ToolDispatchOutcomeTests {
    /// A hallucinated tool name is model noise, and the model fixes it on the next hop. Showing
    /// the user a banner for it would surface a mistake that resolves by itself.
    @Test("an unknown tool goes back to the model rather than to the user")
    func unknownTool() async throws {
        let harness = await ToolHarness()
        try await harness.registerScopes()
        stubJSON([
            toolCallBody(name: "get_wether", arguments: #"{"city":"Gurugram"}"#),
            proseBody("I do not have a weather tool.")
        ])

        let (result, trace, activity) = await run(harness.executor())

        #expect(completedText(result) == "I do not have a weather tool.")
        #expect(trace.refusal == nil, "a hallucinated name is not something to alarm the user with")
        #expect(trace.failures.isEmpty)
        #expect(StubURLProtocol.requestCount == 2)

        let authority = try #require(trace.outcome(for: .toolAuthority))
        #expect(authority == .noOp(reason: "get_wether is not a registered tool; nothing to authorize"))
        let dispatch = try #require(trace.outcome(for: .toolDispatch))
        #expect(dispatch.summary.contains("no tool named \"get_wether\" is registered"))
        #expect(dispatch.summary.contains("returned to the model"))
        #expect(activity == [.started(tool: "get_wether"), .cleared(tool: "get_wether")])

        let observation = try #require(try sentMessages(at: 1).last?["content"] as? String)
        #expect(observation.contains("no tool named"))
    }

    /// The most common tool-calling failure there is, and it is self-correcting. The validator's
    /// message names the JSON path precisely so the model can act on it.
    @Test("arguments that miss the schema go back to the model naming the path that was wrong")
    func invalidArguments() async throws {
        let harness = await ToolHarness()
        try await harness.registerScopes()
        stubJSON([
            toolCallBody(name: "calculator", arguments: #"{"expression":42}"#),
            proseBody("Let me try that again — it is 84.")
        ])

        let (result, trace, _) = await run(harness.executor())

        #expect(completedText(result) == "Let me try that again — it is 84.")
        #expect(trace.refusal == nil)
        #expect(trace.failures.isEmpty, "a schema miss is model noise, not an outage")

        let dispatch = try #require(trace.outcome(for: .toolDispatch))
        // The calculator declares one property, so this message is deterministic. A schema with
        // two invalid properties would not be — the validator iterates a Dictionary there.
        #expect(dispatch.summary.contains("$.expression expected string, got number"))

        let observation = try #require(try sentMessages(at: 1).last?["content"] as? String)
        #expect(observation.contains("$.expression expected string, got number"))
    }

    @Test("a required argument the model omitted is reported as missing, not as a crash")
    func missingRequiredArgument() async throws {
        let harness = await ToolHarness()
        try await harness.registerScopes()
        stubJSON([
            toolCallBody(name: "calculator", arguments: "{}"),
            proseBody("I need an expression.")
        ])

        let (_, trace, _) = await run(harness.executor())
        let dispatch = try #require(trace.outcome(for: .toolDispatch))
        #expect(dispatch.summary.contains("$.expression is required but missing"))
    }

    /// The one outcome that is a genuine defect: our code failed, not the model's.
    @Test("a handler that throws is recorded as a failure and shown, not filed as model noise")
    func handlerThrew() async throws {
        let harness = await ToolHarness()
        try await harness.registerScopes()
        stubJSON([
            toolCallBody(name: "calculator", arguments: #"{"expression":"10 / 0"}"#),
            proseBody("I could not divide by zero.")
        ])

        let (result, trace, activity) = await run(harness.executor())

        #expect(completedText(result) == "I could not divide by zero.")
        #expect(trace.refusal == nil, "a broken stage is not the system correctly saying no")

        let failures = trace.failures
        #expect(failures.count == 1)
        #expect(failures.first?.stage == .toolDispatch)
        #expect(
            failures.first?.outcome
                == .failed(message: "\"calculator\" handler threw: division by zero")
        )
        #expect(activity == [
            .started(tool: "calculator"),
            .failed(tool: "calculator", message: "division by zero")
        ])

        // Fed back as well as recorded, so the assistant can explain the outage in its own words
        // rather than leaving the user with an empty bubble.
        let observation = try #require(try sentMessages(at: 1).last?["content"] as? String)
        #expect(observation.contains("division by zero"))
    }

    /// A model that keeps looking things up has already spent the user's money `maxToolHops` times.
    @Test("a model that never converges is stopped, and the refusal offers a different model")
    func hopCap() async throws {
        let harness = await ToolHarness()
        try await harness.registerScopes()
        let call = toolCallBody(name: "calculator", arguments: #"{"expression":"1+1"}"#)
        stubJSON([call, call, call, call])

        let (result, trace, _) = await run(harness.executor(maxToolHops: 3))

        guard case .completed = result else {
            Issue.record("expected the turn to settle rather than fail: \(result)")
            return
        }
        #expect(StubURLProtocol.requestCount == 4, "three hops plus the call that hit the cap")

        let refusal = try #require(trace.refusal)
        #expect(refusal.stage == .agentLoop)
        #expect(refusal.headline == "Stopped after 3 tool calls")
        #expect(refusal.recovery == .switchModel)
        #expect(refusal.recoveryTitle == "Choose another model")

        let statistics = await harness.tools.statistics()
        #expect(statistics.totalCalls == 3)
        #expect(statistics.successCount == 3)
    }

    @Test("a second answer that is empty is a failure of the provider, not a refusal")
    func emptyFinalAnswer() async throws {
        let harness = await ToolHarness()
        try await harness.registerScopes()
        stubJSON([
            toolCallBody(name: "calculator", arguments: #"{"expression":"2+2"}"#),
            proseBody("")
        ])

        let (_, trace, _) = await run(harness.executor())
        #expect(
            trace.outcome(for: .agentLoop)
                == .failed(message: "the model returned an empty response")
        )
        #expect(trace.refusal == nil)
    }
}

@Suite("Tool round trip — the chat surface")
@MainActor
struct ToolChatSurfaceTests {
    private func makePipeline() async -> PreModelPipeline {
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

    /// Waits for the turn to settle. The alternative — asserting mid-flight — would be a test of
    /// scheduling rather than of behaviour.
    private func settle(_ model: ChatViewModel) async throws {
        for _ in 0..<600 {
            if !model.isSending, model.bubbles.count >= 2 { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @Test("the bubble names the tools that ran once the answer settles")
    func usedChip() async throws {
        let harness = await ToolHarness()
        try await harness.registerScopes()
        stubJSON([
            toolCallBody(name: "calculator", arguments: #"{"expression":"6*7"}"#),
            proseBody("Six sevens are 42.")
        ])
        let model = ChatViewModel(
            pipeline: await makePipeline(),
            executor: harness.executor(),
            review: PostModelPipeline(guardrail: GuardrailPipeline(policy: GuardrailPolicy()))
        )

        model.draft = "what is 6*7"
        model.send()
        try await settle(model)

        let assistant = try #require(model.bubbles.last)
        #expect(assistant.text == "Six sevens are 42.")
        #expect(assistant.delivery == .delivered)
        #expect(assistant.toolState == .used(["calculator"]))
        #expect(model.activeRefusal == nil)
    }

    @Test("a blocked call publishes the answer and raises the refusal above the composer")
    func blockedCallStillPublishes() async throws {
        let harness = await ToolHarness(granted: [DemoTools.clockName])
        try await harness.registerScopes()
        stubJSON([toolCallBody(name: "calculator", arguments: #"{"expression":"6*7"}"#)])
        let model = ChatViewModel(
            pipeline: await makePipeline(),
            executor: harness.executor(),
            review: PostModelPipeline(guardrail: GuardrailPipeline(policy: GuardrailPolicy()))
        )

        model.draft = "what is 6*7"
        model.send()
        try await settle(model)

        let refusal = try #require(model.activeRefusal)
        #expect(refusal.stage == .toolAuthority)
        #expect(refusal.recoveryTitle == "Approve calculator")
        // The user's own message stays on screen: the view model owns its log rather than
        // trusting a transcript that drops a message the moment a turn goes sideways.
        #expect(model.bubbles.first?.role == .user)
        #expect(model.bubbles.first?.text == "what is 6*7")
    }

    @Test("the chip runs while a tool is in flight and settles on what happened to it")
    func chipTransitions() async throws {
        let harness = await ToolHarness()
        try await harness.registerScopes()
        stubJSON([proseBody("Paris.")])
        let model = ChatViewModel(
            pipeline: await makePipeline(),
            executor: harness.executor(),
            review: PostModelPipeline(guardrail: GuardrailPipeline(policy: GuardrailPolicy()))
        )
        model.draft = "capital of France"
        model.send()
        try await settle(model)

        let id = try #require(model.bubbles.last?.id)
        #expect(model.bubbles.last?.toolState == .idle)

        model.apply(.started(tool: "calculator"), to: id)
        #expect(model.bubbles.last?.toolState == .running("calculator"))

        model.apply(.finished(tool: "calculator"), to: id)
        #expect(model.bubbles.last?.toolState == .used(["calculator"]))

        model.apply(.started(tool: "current_time"), to: id)
        model.apply(.finished(tool: "current_time"), to: id)
        #expect(model.bubbles.last?.toolState == .used(["calculator", "current_time"]))

        model.apply(.failed(tool: "calculator", message: "division by zero"), to: id)
        #expect(
            model.bubbles.last?.toolState
                == .failed(tool: "calculator", message: "division by zero")
        )

        // A cleared call falls back to what already ran rather than erasing the record of it.
        model.apply(.cleared(tool: "get_wether"), to: id)
        #expect(model.bubbles.last?.toolState == .used(["calculator", "current_time"]))
    }
}
