import CostEstimatorKit
import Foundation
import ProviderGatewayKit
import QuotaGovernorKit
import RetryPolicyKit
import Testing
import TokenMeterKit
import UsageRecoveryKit
@testable import AIChatApp

/// One SSE event carrying `content`. The content here never contains a quote or a backslash.
private func recoveryEvent(_ content: String, finish: String? = nil, usage: Bool = false) -> String {
    let reason = finish.map { "\"\($0)\"" } ?? "null"
    let tail = usage ? #","usage":{"prompt_tokens":18,"completion_tokens":7,"cost":0.000104}"# : ""
    return #"data: {"id":"gen-cut-1","model":"openai/gpt-4o","choices":[{"delta":{"content":""#
        + content + #""},"finish_reason":"# + reason + "}]" + tail + "}\n\n"
}

/// Three fragments, a finish reason, `[DONE]`, and no usage chunk anywhere.
private let noUsageBody = recoveryEvent("Use a background ") + recoveryEvent("URLSession and ")
    + recoveryEvent("upload from a file.", finish: "stop") + "data: [DONE]\n\n"

private let usageBody = recoveryEvent("Hi ") + recoveryEvent("there", finish: "stop", usage: true)
    + "data: [DONE]\n\n"

private func sseStub(
    _ body: String,
    headers: [String: String] = [:],
    failAfterBody: URLError? = nil
) -> StubURLProtocol.Stub {
    var merged = ["Content-Type": "text/event-stream"]
    for (key, value) in headers { merged[key] = value }
    return StubURLProtocol.Stub(statusCode: 200, headers: merged, body: Data(body.utf8), failAfterBody: failAfterBody)
}

private func recoveryTurn(_ text: String = "How do I upload in the background?") -> PreparedTurn {
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

/// Returns at once, so a lookup schedule runs without waiting.
private struct InstantSleeper: Sleeping {
    func sleep(for duration: Duration) async throws {}
}

/// Answers from a script, one per lookup; the last answer repeats.
private actor ScriptedGenerations: GenerationLookup {
    private let answers: [LookupAnswer]
    private(set) var calls: [String] = []

    init(_ answers: [LookupAnswer]) {
        self.answers = answers
    }

    func lookUp(_ id: GenerationID) async throws -> LookupAnswer {
        calls.append(id.rawValue)
        return answers[min(calls.count, answers.count) - 1]
    }
}

/// Collects what reached the month's spend.
private final class SpendLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []

    func add(_ microcents: Int) {
        lock.lock()
        defer { lock.unlock() }
        values.append(microcents)
    }

    var all: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private func recoveryExecutor(
    _ harness: ExecutorHarness,
    recovery: LiveUsageRecovery?,
    spent: SpendLog
) -> TurnExecutor {
    TurnExecutor(
        provider: OpenRouterProvider(
            configuration: OpenRouterConfiguration(apiKey: "sk-or-v1-test", streaming: true),
            session: StubURLProtocol.makeSession(),
            usageObserver: harness.usage
        ),
        idempotency: harness.idempotency,
        profiler: harness.profiler,
        estimator: CostEstimator(priceBook: ExecutorHarness.priceBook()),
        governor: harness.governor,
        retryPolicy: ExponentialBackoffRetryPolicy(maxAttempts: 1),
        meter: harness.meter,
        usage: harness.usage,
        scopes: harness.scopes,
        usageRecovery: recovery,
        onSettled: { spent.add($0) }
    )
}

private func runTurn(
    _ executor: TurnExecutor,
    _ turn: PreparedTurn = recoveryTurn(),
    conversationID: String = "recovery-1"
) async -> (TurnResult, PipelineTrace) {
    var trace = PipelineTrace()
    let result = await executor.execute(turn, conversationID: conversationID, trace: &trace, onDelta: { _ in })
    return (result, trace)
}

private func billed(input: Int = 22, output: Int = 31, microcents: Int? = 42_000) throws -> BilledUsage {
    try BilledUsage(inputTokens: input, outputTokens: output, microcents: microcents, upstreamProvider: "OpenAI")
}

@Suite("UsageRecoveryKit - a call whose usage never arrived", .serialized)
struct UsageRecoveryStageTests {
    @Test("a stream that ends without usage is held at its upper bound and settled from the bill")
    func heldThenBilled() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        await harness.registerPricing()
        StubURLProtocol.setStubs([sseStub(noUsageBody)])
        let lookup = ScriptedGenerations([.notYetAvailable, .billed(try billed())])
        let recovery = LiveUsageRecovery(registry: harness.registry, lookup: lookup, sleeper: InstantSleeper())
        let spent = SpendLog()

        let (result, trace) = await runTurn(recoveryExecutor(harness, recovery: recovery, spent: spent))

        guard case let .completed(completion) = result else {
            Issue.record("expected .completed, got \(result)")
            return
        }
        #expect(completion.text == "Use a background URLSession and upload from a file.")
        #expect(completion.promptTokens == 0)
        #expect(trace.outcome(for: .metering) == .noOp(reason: "the provider reported no usage for this call"))
        // 51 bytes in 3 chunks: 9...26 output tokens; the prompt estimate 20 is held as 15...30.
        // At $25/$100 per million that is 127500...335000 microcents, and the budget holds the top.
        #expect(
            trace.outcome(for: .usageRecovery) == .ran(
                detail: "1 call(s) ended without usage (completed without usage); held 335000 microcents, "
                    + "the upper bound of 127500-335000 (output 9...26 tokens, ran to its end); "
                    + "asking OpenRouter for gen-cut-1"
            )
        )
        #expect(trace.outcome(for: .budgetSettle)?.summary.contains("335000") == true)

        // The resolution runs in the background and may already be done here, so only the final
        // state is asserted: the month hears the bill once, and never the 335000 bound it held.
        await recovery.drain()
        #expect(spent.all == [42_000])
        #expect(await lookup.calls == ["gen-cut-1", "gen-cut-1"])
        let resolutions = await recovery.resolutions
        #expect(resolutions.count == 1)
        #expect(resolutions.first?.isBilled == true)
        // 22 in / 31 out at $25/$100 per million.
        #expect(await harness.meter.cost(for: "openai/gpt-4o") == Decimal(string: "0.00365"))
    }

    @Test("without a billing lookup the stage says so and the turn settles at zero, as before")
    func notWired() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        await harness.registerPricing()
        StubURLProtocol.setStubs([sseStub(noUsageBody)])
        let spent = SpendLog()

        let (_, trace) = await runTurn(recoveryExecutor(harness, recovery: nil, spent: spent))

        #expect(
            trace.outcome(for: .usageRecovery) == .skipped(
                reason: "1 call(s) ended without usage, but no billing lookup is wired into this executor; "
                    + "settled at zero"
            )
        )
        #expect(spent.all.isEmpty)
    }

    @Test("a model with no price yet cannot be bounded, and the stage says why")
    func unpriced() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        StubURLProtocol.setStubs([sseStub(noUsageBody)])
        let lookup = ScriptedGenerations([.notYetAvailable])
        let recovery = LiveUsageRecovery(registry: harness.registry, lookup: lookup, sleeper: InstantSleeper())

        let (_, trace) = await runTurn(recoveryExecutor(harness, recovery: recovery, spent: SpendLog()))

        #expect(
            trace.outcome(for: .usageRecovery) == .skipped(
                reason: "1 call(s) ended without usage, but there is no price for openai/gpt-4o yet "
                    + "(the model catalogue has not loaded), so nothing could be bounded; settled at zero"
            )
        )
        await recovery.drain()
        #expect(await lookup.calls.isEmpty)
    }

    @Test("a turn that reported its usage is metered as before and recovery has nothing to do")
    func reported() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        await harness.registerPricing()
        StubURLProtocol.setStubs([sseStub(usageBody)])
        let spent = SpendLog()
        let recovery = LiveUsageRecovery(
            registry: harness.registry,
            lookup: ScriptedGenerations([.notYetAvailable]),
            sleeper: InstantSleeper()
        )

        let (_, trace) = await runTurn(recoveryExecutor(harness, recovery: recovery, spent: spent))

        #expect(trace.outcome(for: .usageRecovery) == .noOp(reason: "the provider reported this turn's usage"))
        #expect(trace.outcome(for: .metering) == .ran(detail: "18 in / 7 out"))
        #expect(spent.all == [10_400])
        #expect(await harness.usage.unmeteredCount == 0)
    }

    @Test("a turn that records nothing is not metered on the previous turn's usage")
    func noStaleUsage() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        await harness.registerPricing()
        let executor = recoveryExecutor(harness, recovery: nil, spent: SpendLog())
        StubURLProtocol.setStubs([sseStub(usageBody)])
        _ = await runTurn(executor, recoveryTurn("first"))

        StubURLProtocol.setStubs([sseStub(noUsageBody)])
        let (result, trace) = await runTurn(executor, recoveryTurn("second"))

        guard case let .completed(completion) = result else {
            Issue.record("expected .completed, got \(result)")
            return
        }
        // Before 2026-10-19 this read the first turn's "18 in / 7 out" and billed it again.
        #expect(trace.outcome(for: .metering) == .noOp(reason: "the provider reported no usage for this call"))
        #expect(completion.promptTokens == 0)
        #expect(completion.completionTokens == 0)
    }

    @Test("a connection that drops mid-answer settles at the bound instead of releasing the hold")
    func droppedConnection() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        await harness.registerPricing()
        let partial = recoveryEvent("Use a background ") + recoveryEvent("URLSession and ")
        StubURLProtocol.setStubs([sseStub(partial, failAfterBody: URLError(.networkConnectionLost))])
        let lookup = ScriptedGenerations([.billed(try billed(output: 60, microcents: 65_000))])
        let recovery = LiveUsageRecovery(registry: harness.registry, lookup: lookup, sleeper: InstantSleeper())
        let spent = SpendLog()

        let (result, trace) = await runTurn(recoveryExecutor(harness, recovery: recovery, spent: spent))

        guard case .refused = result else {
            Issue.record("expected a refusal for the dropped answer, got \(result)")
            return
        }
        let detail = trace.outcome(for: .usageRecovery)?.summary ?? ""
        #expect(detail.contains("(connection dropped)"))
        #expect(detail.contains("cancellation billing unknown"))
        #expect(trace.outcome(for: .budgetSettle) != nil)
        await recovery.drain()
        #expect(spent.all == [65_000])
    }
}

@Suite("UsageRecoveryKit - the pieces", .serialized)
struct UsageRecoveryPartsTests {
    private let record = #"{"data":{"id":"gen-cut-1","tokens_prompt":20,"tokens_completion":30,"#
        + #""native_tokens_prompt":22,"native_tokens_completion":31,"total_cost":0.00042,"#
        + #""cancelled":true,"provider_name":"OpenAI"}}"#

    private func lookup() -> OpenRouterGenerationLookup {
        OpenRouterGenerationLookup(
            configuration: OpenRouterConfiguration(apiKey: "sk-or-v1-test"),
            session: StubURLProtocol.makeSession()
        )
    }

    @Test("the lookup reads native counts and the charged cost, with the key and the id")
    func lookupBilled() async throws {
        StubURLProtocol.respond(json: record)
        let answer = try await lookup().lookUp(try GenerationID("gen-cut-1"))
        let expected = try BilledUsage(
            inputTokens: 22, outputTokens: 31, microcents: 42_000, cancelled: true, upstreamProvider: "OpenAI"
        )
        #expect(answer == .billed(expected))
        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/generation?id=gen-cut-1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-v1-test")
    }

    @Test("the normalized counts stand in when the native ones are missing")
    func lookupNormalized() throws {
        let usage = try OpenRouterGenerationLookup.usage(
            from: Data(#"{"data":{"tokens_prompt":20,"tokens_completion":30}}"#.utf8)
        )
        #expect(usage == (try BilledUsage(inputTokens: 20, outputTokens: 30)))
        let empty = try OpenRouterGenerationLookup.usage(from: Data(#"{"data":{}}"#.utf8))
        #expect(empty == (try BilledUsage(inputTokens: 0, outputTokens: 0)))
    }

    @Test("not found means not yet; any other status, or a body that is not a record, throws")
    func lookupStatuses() async throws {
        StubURLProtocol.respond(statusCode: 404, json: #"{"error":{"message":"Not Found"}}"#)
        #expect(try await lookup().lookUp(try GenerationID("gen-x")) == .notYetAvailable)
        StubURLProtocol.respond(statusCode: 500, json: "{}")
        await #expect(throws: OpenRouterGenerationLookup.Failure.self) {
            try await lookup().lookUp(try GenerationID("gen-x"))
        }
        #expect(OpenRouterGenerationLookup.Failure(status: 500).description == "the generation lookup answered HTTP 500")
        StubURLProtocol.respond(json: "[]")
        await #expect(throws: DecodingError.self) {
            try await lookup().lookUp(try GenerationID("gen-x"))
        }
    }

    @Test("the provider reports a stream without usage, preferring the header's id")
    func providerReportsUnmetered() async throws {
        let recorder = UsageRecorder()
        StubURLProtocol.setStubs([sseStub(noUsageBody, headers: ["X-Generation-Id": "gen-header-9"])])
        let provider = OpenRouterProvider(
            configuration: OpenRouterConfiguration(apiKey: "sk-or-v1-test"),
            session: StubURLProtocol.makeSession(),
            usageObserver: recorder,
            effort: ReasoningEffortBox(.high)
        )
        let request = LLMRequest(messages: [LLMMessage(role: .user, content: "hi")], maxOutputTokens: 300)
        for try await _ in provider.stream(request: request) {}

        let calls = await recorder.unmetered(after: 0)
        #expect(
            calls == [
                UnmeteredCall(
                    generationID: "gen-header-9",
                    model: "openai/gpt-4o",
                    receivedText: "Use a background URLSession and upload from a file.",
                    contentChunks: 3,
                    maxOutputTokens: 300,
                    reasoningCeiling: 240,
                    ending: .completed
                )
            ]
        )
        #expect(await recorder.lastRecord(after: 0) == nil)
        await recorder.reset()
        #expect(await recorder.unmeteredCount == 0)
    }

    @Test("a stream with no chunk and no id is not a generation, and nothing is reported")
    func providerIgnoresEmptyStreams() async throws {
        let recorder = UsageRecorder()
        StubURLProtocol.setStubs([sseStub("data: [DONE]\n\n")])
        let provider = OpenRouterProvider(
            configuration: OpenRouterConfiguration(apiKey: "sk-or-v1-test"),
            session: StubURLProtocol.makeSession(),
            usageObserver: recorder
        )
        let request = LLMRequest(messages: [LLMMessage(role: .user, content: "hi")])
        for try await _ in provider.stream(request: request) {}
        #expect(await recorder.unmeteredCount == 0)
        await NullUsageObserver().recordUnmetered(
            UnmeteredCall(
                generationID: nil, model: "m", receivedText: "", contentChunks: 0,
                maxOutputTokens: 1, reasoningCeiling: 0, ending: .completed
            )
        )
    }

    @Test("a dropped connection and a stopped read are told apart")
    func endings() {
        #expect(OpenRouterProvider.ending(for: CancellationError()) == .stoppedReading)
        #expect(OpenRouterProvider.ending(for: URLError(.cancelled)) == .stoppedReading)
        #expect(OpenRouterProvider.ending(for: URLError(.networkConnectionLost)) == .dropped)
        #expect(LiveUsageRecovery.ending(.completed, cutBy: nil) == .completedWithoutUsage)
        #expect(LiveUsageRecovery.ending(.stoppedReading, cutBy: nil) == .cancelled(reason: "the app stopped reading"))
        #expect(
            LiveUsageRecovery.ending(.stoppedReading, cutBy: "cut by the repetition guard")
                == .cancelled(reason: "cut by the repetition guard")
        )
        #expect(LiveUsageRecovery.ending(.dropped, cutBy: nil) == .connectionDropped)
    }

    @Test("the repetition guard's refusal names the cut")
    func cutReason() {
        var trace = PipelineTrace()
        #expect(TurnExecutor.cutReason(trace) == nil)
        trace.record(
            .degenerationGuard,
            .refused(Refusal(stage: .degenerationGuard, headline: "h", explanation: "e", recovery: .retryLater(after: nil)))
        )
        #expect(TurnExecutor.cutReason(trace) == "cut by the repetition guard")
    }

    @Test("effort shares follow OpenRouter's reasoning allocation")
    func effortShares() {
        #expect(ReasoningEffort.allCases.map(\.reasoningPercent) == [20, 50, 80, 95])
    }

    @Test("a call with no generation id keeps its bound, and the month is told the bound")
    func noGenerationID() async throws {
        let registry = PricingRegistry()
        await registry.register(ModelPricing(inputPerMillion: 1, outputPerMillion: 2), for: "m")
        let lookup = ScriptedGenerations([.notYetAvailable])
        let recovery = LiveUsageRecovery(registry: registry, lookup: lookup, sleeper: InstantSleeper())
        let spent = SpendLog()
        let call = UnmeteredCall(
            generationID: nil, model: "m", receivedText: "abcdefgh", contentChunks: 2,
            maxOutputTokens: 100, reasoningCeiling: 0, ending: .dropped
        )

        let decision = await recovery.hold(
            [call], promptTokens: 40, cutBy: nil,
            sinks: LiveUsageRecovery.Sinks(meter: TokenMeter(registry: registry), spend: { spent.add($0) })
        )

        guard case let .held(held) = decision else {
            Issue.record("expected a hold, got \(decision)")
            return
        }
        // Input 30...60, output 2...100 (unknown upstream): upper 60 x 100 + 100 x 200 = 26000.
        #expect(held.microcents == 26_000)
        #expect(held.tokens == 160)
        #expect(held.detail.hasSuffix("no generation id arrived, so the upper bound stands"))
        await recovery.drain()
        #expect(spent.all == [26_000])
        #expect(await lookup.calls.isEmpty)
    }

    @Test("a call that cannot be described is skipped, not guessed")
    func indescribable() async {
        let registry = PricingRegistry()
        await registry.register(ModelPricing(inputPerMillion: 1, outputPerMillion: 2), for: "m")
        let recovery = LiveUsageRecovery(
            registry: registry,
            lookup: ScriptedGenerations([.notYetAvailable]),
            sleeper: InstantSleeper()
        )
        let impossible = UnmeteredCall(
            generationID: "gen-1", model: "m", receivedText: "", contentChunks: 0,
            maxOutputTokens: 0, reasoningCeiling: 0, ending: .completed
        )
        let decision = await recovery.hold(
            [impossible], promptTokens: 1, cutBy: nil,
            sinks: LiveUsageRecovery.Sinks(meter: TokenMeter(registry: registry), spend: { _ in })
        )
        #expect(decision == .skipped("no call could be described for a bound"))
        // `ModelPricing` clamps a negative price to zero, so the catalogue cannot hand over one
        // `TokenPrice` refuses; a free model bounds at zero rather than failing.
        #expect(
            LiveUsageRecovery.price(ModelPricing(inputPerMillion: -1, outputPerMillion: 0))
                == (try? UsageRecoveryKit.TokenPrice(inputPerMillion: 0, outputPerMillion: 0))
        )
    }

    @Test("the stage table names UsageRecoveryKit as its owner")
    func owner() {
        #expect(PipelineStage.usageRecovery.package == "UsageRecoveryKit")
        #expect(PipelineStage.usageRecovery.title == "Usage that never arrived")
    }
}
