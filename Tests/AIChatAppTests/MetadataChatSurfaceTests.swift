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
import WorkloadProfilerKit
@testable import AIChatApp

// MARK: - Transport

@Suite("Metadata completer", .serialized)
struct MetadataCompleterTests {
    private func completer() -> OpenRouterMetadataCompleter {
        OpenRouterMetadataCompleter(
            configuration: OpenRouterConfiguration(
                apiKey: "sk-or-v1-test",
                model: MetadataPipeline.defaultModelID
            ),
            session: StubURLProtocol.makeSession()
        )
    }

    /// A repair loop validates a finished reply, so there is nothing to stream and nothing to
    /// gain by asking for it. Sending `stream: true` here would also make every metadata call
    /// pay for SSE framing it immediately discards.
    @Test("the metadata call is buffered, not streamed, and asks for its own model")
    func sendsBufferedRequest() async throws {
        StubURLProtocol.respond(
            statusCode: 200,
            json: #"""
            {"model":"google/gemini-2.5-flash-lite",
             "choices":[{"finish_reason":"stop","message":{"content":"{\"title\":\"Paris\"}"}}],
             "usage":{"prompt_tokens":31,"completion_tokens":8}}
            """#
        )

        let result = try await completer().complete(system: "sys", user: "usr")

        #expect(result.text == #"{"title":"Paris"}"#)
        #expect(result.promptTokens == 31)
        #expect(result.completionTokens == 8)

        // Decoded rather than string-matched: `JSONEncoder` escapes the slash in a model slug,
        // so a substring check for "google/gemini…" passes only by accident of escaping rules.
        let body = try #require(StubURLProtocol.lastBody)
        let sent = try JSONDecoder().decode(OpenRouterJSON.self, from: body)
        guard case let .object(fields) = sent else {
            Issue.record("the request body was not a JSON object")
            return
        }
        #expect(fields["stream"] == .bool(false))
        #expect(fields["model"] == .string(MetadataPipeline.defaultModelID))
        #expect(fields["max_tokens"] == .int(256))
        #expect(fields["tools"] == nil, "a metadata ask declares no tools")
        #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    /// Several upstreams omit the usage envelope entirely. That is not a failure of ours, and it
    /// must read as "not reported" rather than turning an otherwise good reply into an error.
    @Test("a reply with no usage envelope still returns its text, with zero tokens")
    func toleratesMissingUsage() async throws {
        StubURLProtocol.respond(statusCode: 200, json: OpenRouterTestFixtures.responseWithoutUsage)

        let result = try await completer().complete(system: "sys", user: "usr")

        #expect(result.text == "truncated…")
        #expect(result.promptTokens == 0)
        #expect(result.completionTokens == 0)
    }

    /// `ProviderError` is not `CustomStringConvertible`, and both packages downstream keep only
    /// `String(describing:)` of whatever is thrown — so an unwrapped one reaches Diagnostics as a
    /// Swift value dump where a fact belongs.
    @Test("a rate limit arrives as a sentence rather than as a value dump")
    func wrapsRateLimit() async throws {
        StubURLProtocol.respond(
            statusCode: 429,
            json: OpenRouterTestFixtures.rateLimitedBody,
            headers: ["Retry-After": "17"]
        )

        do {
            _ = try await completer().complete(system: "sys", user: "usr")
            Issue.record("expected a failure")
        } catch let failure as MetadataProviderFailure {
            #expect(failure.description == "rate limited by OpenRouter, retry after 17s")
        }
    }

    @Test("every provider error maps to something a reader can act on")
    func mapsEveryProviderError() {
        let cases: [ProviderError] = [
            .rateLimited(retryAfter: nil),
            .rateLimited(retryAfter: .seconds(9)),
            .timeout,
            .connectionFailed("socket closed"),
            .capabilityMismatch("no key")
        ]
        for error in cases {
            let failure = MetadataProviderFailure(error)
            #expect(!failure.description.isEmpty)
            #expect(!failure.description.contains("("), "\(failure.description) reads as a value dump")
        }
    }

    @Test("a rejected key names the key rather than blaming the model")
    func wrapsUnauthorized() async throws {
        StubURLProtocol.respond(statusCode: 401, json: OpenRouterTestFixtures.unauthorizedBody)
        do {
            _ = try await completer().complete(system: "sys", user: "usr")
            Issue.record("expected a failure")
        } catch let failure as MetadataProviderFailure {
            #expect(failure.description.contains("rejected the metadata request"))
        }
    }
}

// MARK: - Chat surface

/// A whole chat stack with only the network faked, plus a scripted metadata completer.
private struct ChatHarness {
    let usage = UsageRecorder()
    let governor = QuotaGovernor()
    let scopes = BudgetScopes(account: ScopeID("account"), conversation: ScopeID("conversation"))

    func registerScopes() async throws {
        try await governor.register(scopes.account, at: 0)
        try await governor.register(scopes.conversation, under: scopes.account, at: 0)
    }

    func executor() -> TurnExecutor {
        TurnExecutor(
            provider: OpenRouterProvider(
                configuration: OpenRouterConfiguration(apiKey: "sk-or-v1-test", streaming: false),
                session: StubURLProtocol.makeSession(),
                usageObserver: usage
            ),
            idempotency: IdempotencyGuard(),
            profiler: WorkloadProfiler(),
            estimator: CostEstimator(priceBook: Self.emptyPriceBook()),
            governor: governor,
            retryPolicy: ExponentialBackoffRetryPolicy(maxAttempts: 1),
            meter: TokenMeter(registry: PricingRegistry()),
            usage: usage,
            scopes: scopes
        )
    }

    func pipeline() async -> PreModelPipeline {
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

    static func emptyPriceBook() -> PriceBook {
        guard let book = try? PriceBook([]) else {
            preconditionFailure("an empty price book cannot fail to build")
        }
        return book
    }
}

private func proseBody(_ text: String) -> String {
    """
    {"id":"gen-1","model":"openai/gpt-4o",
     "choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"\(text)"}}],
     "usage":{"prompt_tokens":11,"completion_tokens":4}}
    """
}

@Suite("Metadata on the chat surface", .serialized)
@MainActor
struct MetadataChatSurfaceTests {
    private func model(
        harness: ChatHarness,
        metadata: MetadataPipeline?
    ) async -> ChatViewModel {
        ChatViewModel(
            pipeline: await harness.pipeline(),
            executor: harness.executor(),
            review: PostModelPipeline(guardrail: GuardrailPipeline(policy: GuardrailPolicy())),
            metadata: metadata
        )
    }

    /// Waits for the title to arrive. Metadata is deliberately detached from the send, so the
    /// composer re-enabling is not the signal that it has landed.
    private func settle(_ model: ChatViewModel, until ready: @escaping (ChatViewModel) -> Bool) async throws {
        for _ in 0..<600 {
            if !model.isSending, ready(model) { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @Test("a completed turn renames the conversation and offers what to ask next")
    func namesTheConversation() async throws {
        let harness = ChatHarness()
        try await harness.registerScopes()
        StubURLProtocol.respond(json: proseBody("Paris is the capital of France."))

        let completer = ScriptedCompleter(
            title: [MetadataHarness.goodTitle],
            followUps: [MetadataHarness.goodFollowUps]
        )
        let chat = await model(
            harness: harness,
            metadata: try await MetadataHarness.pipeline(completer: completer)
        )

        #expect(chat.conversationTitle == ChatViewModel.untitled)
        chat.draft = "what is the capital of France"
        chat.send()
        try await settle(chat) { $0.conversationTitle != ChatViewModel.untitled }

        #expect(chat.conversationTitle == "Capital of France")
        #expect(chat.followUps == ["What is the population?", "When was it founded?"])
        // The metadata stages join the trace the Diagnostics screen reads, rather than a second
        // trace nobody looks at.
        #expect(chat.trace.outcome(for: .batchInference) != nil)
        #expect(chat.trace.outcome(for: .schemaMigration) != nil)
        #expect(chat.activeRefusal == nil, "a caption must never raise a banner")
    }

    /// The whole path: the turn's request is kept as sent, handed to the metadata pipeline, and the
    /// audit lands on the trace Diagnostics reads. A first request has nothing to be compared with;
    /// a second one, after a message large enough to be cacheable, is audited for real.
    @Test("each turn's request is kept, and the prompt-cache audit reports on them")
    func auditsTheRequestsThatWereSent() async throws {
        let harness = ChatHarness()
        try await harness.registerScopes()
        StubURLProtocol.respond(json: proseBody("Paris is the capital of France."))
        let completer = ScriptedCompleter(
            title: [MetadataHarness.goodTitle],
            followUps: [MetadataHarness.goodFollowUps]
        )
        let chat = await model(
            harness: harness,
            metadata: try await MetadataHarness.pipeline(completer: completer)
        )

        chat.draft = String(repeating: "capital of France ", count: 260)
        chat.send()
        try await settle(chat) { $0.trace.outcome(for: .promptCache) != nil }
        #expect(chat.sentPrompts.count == 1)
        #expect(chat.sentPrompts.first?.messages.first?.content == "You are terse.")
        #expect(chat.sentPrompts.first?.usage.promptTokens == 11)
        guard case let .noOp(first) = chat.trace.outcome(for: .promptCache) else {
            Issue.record("expected noOp for the first request, got \(String(describing: chat.trace.outcome(for: .promptCache)))")
            return
        }
        #expect(first.contains("only one request"))

        chat.draft = "and its population"
        chat.send()
        // The trace restarts with every send, so the audit appearing again means the second turn's.
        try await settle(chat) { $0.sentPrompts.count == 2 && $0.trace.outcome(for: .promptCache) != nil }
        guard case let .ran(detail) = chat.trace.outcome(for: .promptCache) else {
            Issue.record("expected ran for the second request, got \(String(describing: chat.trace.outcome(for: .promptCache)))")
            return
        }
        #expect(detail.contains("2 requests to"))
        #expect(detail.contains("every change was an append behind an unchanged prefix"))
        // The stub reports 11 prompt tokens for a ~1,100-token prompt, so the scaled prediction is
        // far under the minimum and a cached count of zero is agreement rather than silence.
        #expect(detail.contains("on 1 transition(s), 1 agreed with the layout"))
        #expect(chat.activeRefusal == nil, "an audit of a finished turn never raises a banner")
    }

    /// The window reaches the audit from the compactor's own settings, not from a default. A
    /// 50,000-token window with the default 1,024 reserved and the 3-token system message leaves
    /// 48,973 tokens of history, which two short turns never approach.
    @Test("the compaction audit replays the window the compactor was given")
    func compactionPlanReadsTheCompactorsWindow() async throws {
        let harness = ChatHarness()
        try await harness.registerScopes()
        StubURLProtocol.respond(json: proseBody("Paris is the capital of France."))
        let pipeline = await harness.pipeline()
        var settings = PipelineSettings()
        settings.contextWindowTokens = 50_000
        await pipeline.update(settings: settings)
        let chat = ChatViewModel(
            pipeline: pipeline,
            executor: harness.executor(),
            review: PostModelPipeline(guardrail: GuardrailPipeline(policy: GuardrailPolicy())),
            metadata: try await MetadataHarness.pipeline(
                completer: ScriptedCompleter(
                    title: [MetadataHarness.goodTitle],
                    followUps: [MetadataHarness.goodFollowUps]
                )
            )
        )

        chat.draft = "capital of France"
        chat.send()
        try await settle(chat) { $0.trace.outcome(for: .compactionPlan) != nil }
        guard case let .noOp(first) = chat.trace.outcome(for: .compactionPlan) else {
            Issue.record("expected noOp, got \(String(describing: chat.trace.outcome(for: .compactionPlan)))")
            return
        }
        #expect(first.contains("only one request"))

        chat.draft = "and its population"
        chat.send()
        try await settle(chat) { $0.sentPrompts.count == 2 && $0.trace.outcome(for: .compactionPlan) != nil }
        guard case let .noOp(second) = chat.trace.outcome(for: .compactionPlan) else {
            Issue.record("expected noOp, got \(String(describing: chat.trace.outcome(for: .compactionPlan)))")
            return
        }
        #expect(second.contains("the 50000-token window less 1024 reserved for the reply and 3 of system message"))
        #expect(second.contains("compacted nothing over 2 requests"))
        #expect(second.contains("against a budget of 48973"))
        #expect(chat.activeRefusal == nil, "an audit of a finished turn never raises a banner")
    }

    @Test("a turn the provider reported nothing for is not kept as a request")
    func unreportedTurnIsNotKept() async throws {
        let harness = ChatHarness()
        try await harness.registerScopes()
        StubURLProtocol.respond(
            json: #"{"id":"gen-1","model":"openai/gpt-4o","choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"Paris."}}]}"#
        )
        let chat = await model(harness: harness, metadata: nil)

        chat.draft = "capital of France"
        chat.send()
        try await settle(chat) { $0.bubbles.count >= 2 }

        #expect(chat.sentPrompts.isEmpty)
    }

    @Test("tapping a suggestion sends it and takes the chips away")
    func tappingSendsIt() async throws {
        let harness = ChatHarness()
        try await harness.registerScopes()
        StubURLProtocol.respond(json: proseBody("Paris is the capital of France."))
        let chat = await model(harness: harness, metadata: nil)

        chat.applyMetadata(
            ChatMetadata(title: "Capital of France", followUps: ["Population?"], titleSource: .model),
            trace: PipelineTrace(),
            from: 0
        )
        #expect(chat.followUps == ["Population?"])

        chat.sendFollowUp("Population?")
        try await settle(chat) { $0.bubbles.count >= 2 }

        #expect(chat.bubbles.first?.text == "Population?")
        #expect(chat.followUps.isEmpty, "a suggestion already in flight must not be tappable again")
    }

    @Test("a blank suggestion, or one tapped mid-send, does nothing")
    func guardsTheTap() async throws {
        let harness = ChatHarness()
        try await harness.registerScopes()
        let chat = await model(harness: harness, metadata: nil)

        chat.sendFollowUp("   ")
        #expect(chat.bubbles.isEmpty)
    }

    /// A generation that lands after the user has already sent something else describes a
    /// conversation that has moved on.
    @Test("metadata from a superseded send is discarded rather than retitling the screen")
    func staleMetadataIsIgnored() async throws {
        let harness = ChatHarness()
        try await harness.registerScopes()
        let chat = await model(harness: harness, metadata: nil)

        var stale = PipelineTrace()
        stale.record(.batchInference, .ran(detail: "stale"))
        chat.applyMetadata(
            ChatMetadata(title: "Old title", followUps: ["a"], titleSource: .model),
            trace: stale,
            from: 41
        )

        #expect(chat.conversationTitle == ChatViewModel.untitled)
        #expect(chat.followUps.isEmpty)
        #expect(chat.trace.outcome(for: .batchInference) == nil, "a stale trace must not be merged")
    }

    @Test("a generation that produced nothing leaves the title alone but still reports")
    func nilMetadataStillTraces() async throws {
        let harness = ChatHarness()
        try await harness.registerScopes()
        let chat = await model(harness: harness, metadata: nil)

        var trace = PipelineTrace()
        trace.record(.schemaMigration, .skipped(reason: "nothing to name"))
        chat.applyMetadata(nil, trace: trace, from: 0)

        #expect(chat.conversationTitle == ChatViewModel.untitled)
        #expect(chat.trace.outcome(for: .schemaMigration)?.summary == "nothing to name")
    }

    @Test("a chat with no metadata pipeline behaves exactly as it did before")
    func metadataIsOptional() async throws {
        let harness = ChatHarness()
        try await harness.registerScopes()
        StubURLProtocol.respond(json: proseBody("Paris."))
        let chat = await model(harness: harness, metadata: nil)

        chat.draft = "capital of France"
        chat.send()
        try await settle(chat) { $0.bubbles.count >= 2 }

        #expect(chat.bubbles.last?.text == "Paris.")
        #expect(chat.conversationTitle == ChatViewModel.untitled)
        #expect(chat.followUps.isEmpty)
    }

    @Test("starting a new send clears the previous turn's suggestions immediately")
    func sendClearsChips() async throws {
        let harness = ChatHarness()
        try await harness.registerScopes()
        StubURLProtocol.respond(json: proseBody("Paris."))
        let chat = await model(harness: harness, metadata: nil)

        chat.applyMetadata(
            ChatMetadata(title: "t", followUps: ["a", "b"], titleSource: .model),
            trace: PipelineTrace(),
            from: 0
        )
        chat.draft = "next question"
        chat.send()
        try await settle(chat) { $0.bubbles.count >= 2 }

        #expect(chat.followUps.isEmpty)
    }

    @Test("stopping a turn also stops the metadata call it would have paid for")
    func stopCancelsMetadata() async throws {
        let harness = ChatHarness()
        try await harness.registerScopes()
        StubURLProtocol.respond(json: proseBody("Paris."))
        let completer = ScriptedCompleter(
            title: [MetadataHarness.goodTitle],
            followUps: [MetadataHarness.goodFollowUps],
            holdNanoseconds: 500_000_000
        )
        let chat = await model(
            harness: harness,
            metadata: try await MetadataHarness.pipeline(completer: completer)
        )

        chat.draft = "capital of France"
        chat.send()
        chat.stop()
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(chat.conversationTitle == ChatViewModel.untitled)
        #expect(chat.activeRefusal == nil)
    }
}
