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
import Security
import StreamAggregatorKit
import TokenMeterKit
import ToolRegistryKit
import WorkloadProfilerKit
import SwiftUI
import Testing
import UIKit
@testable import AIChatApp

/// What happens when the other side leaves a field out.
///
/// Every fallback in the wire layer exists because some upstream really does omit the field: a
/// tool call with no `id`, an assistant message with `content: null`, a `usage` envelope with only
/// half its counters. Each of these was written as a `??` and, until now, no test had ever taken
/// the right-hand side — which means the default was a guess about what the app would do rather
/// than something it had been seen doing.
@Suite("Wire fields the upstream left out", .serialized)
struct OmittedWireFieldTests {
    private func decodeChunk(_ json: String) throws -> OpenRouterStreamChunk {
        try JSONDecoder().decode(OpenRouterStreamChunk.self, from: Data(json.utf8))
    }

    /// A tool-call fragment with no `index`. OpenAI-compatible providers index their fragments so
    /// that a multi-tool reply can be reassembled; the ones that emit a single call sometimes do
    /// not bother, and folding those into slot 0 is the only reading that reassembles anything.
    @Test("a tool fragment with no index folds into the first slot")
    func toolFragmentWithoutIndex() throws {
        let chunk = try decodeChunk(
            #"{"choices":[{"delta":{"tool_calls":[{"id":"call_1","function":{"name":"c"}}]}}]}"#
        )
        let deltas = chunk.streamDeltas
        guard case let .toolCall(index, id, name, fragment) = deltas.first else {
            Issue.record("expected a tool-call delta, got \(deltas)")
            return
        }
        #expect(index == 0)
        #expect(id == "call_1")
        #expect(name == "c")
        #expect(fragment.isEmpty, "no arguments yet is empty, not nil")
    }

    /// A `usage` envelope carrying only a cost. Reading a missing counter as zero is the only
    /// honest option — the alternative is to drop the whole envelope and lose the cost with it.
    @Test("a usage envelope missing its counters reports zero rather than dropping the cost")
    func usageWithoutCounters() throws {
        let chunk = try decodeChunk(#"{"choices":[],"usage":{"cost":0.00031}}"#)

        guard case let .usage(prompt, completion) = chunk.streamDeltas.first else {
            Issue.record("expected a usage delta, got \(chunk.streamDeltas)")
            return
        }
        #expect(prompt == 0)
        #expect(completion == 0)

        let recorded = try #require(chunk.openRouterUsage(fallbackModel: "openai/gpt-4o"))
        #expect(recorded.promptTokens == 0)
        #expect(recorded.completionTokens == 0)
        #expect(recorded.cachedPromptTokens == 0)
        #expect(recorded.reportedCostUSD == 0.00031)
        #expect(recorded.model == "openai/gpt-4o", "the configured model stands in for a missing one")
    }

    /// The buffered path, which is a different function from the streamed one and has the same
    /// two omissions to survive: a tool call with no id, and a message with no content at all.
    @Test("a buffered reply with no tool-call id and no content still maps")
    func bufferedOmissions() throws {
        let json = """
        {"id":"gen-1","choices":[{"finish_reason":"tool_calls","message":{"role":"assistant",
        "content":null,"tool_calls":[{"type":"function","function":{"name":"calculator",
        "arguments":"{}"}}]}}]}
        """
        let decoded = try JSONDecoder().decode(OpenRouterChatResponse.self, from: Data(json.utf8))
        guard case let .toolCall(call) = try OpenRouterProvider.outcome(from: decoded) else {
            Issue.record("expected a tool call")
            return
        }
        #expect(!call.id.isEmpty, "a call with no id is given one rather than dropped")
        #expect(call.toolName == "calculator")

        let textOnly = """
        {"id":"gen-2","choices":[{"finish_reason":"stop","message":{"role":"assistant"}}]}
        """
        let plain = try JSONDecoder().decode(OpenRouterChatResponse.self, from: Data(textOnly.utf8))
        guard case let .text(content, _) = try OpenRouterProvider.outcome(from: plain) else {
            Issue.record("expected text")
            return
        }
        #expect(content.isEmpty, "a null content is an empty answer, not a crash")
    }

    /// An error body that is not text at all. Rendering it as raw bytes would put mojibake in a
    /// refusal explanation; saying there was no readable body is the truthful alternative.
    @Test("an error body that is not UTF-8 is reported as absent rather than as garbage")
    func nonTextErrorBody() throws {
        let url = try #require(URL(string: "https://openrouter.ai/api/v1/chat/completions"))
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: [:])
        )
        let error = OpenRouterProvider.providerError(
            status: 500,
            headers: response,
            body: Data([0xC3, 0x28, 0xA0])
        )
        guard case let .connectionFailed(message) = error else {
            Issue.record("a 500 is a transport failure, got \(error)")
            return
        }
        #expect(message.contains("no error body"), "got \(message)")
    }

    /// The streamed path assembles a tool call across fragments; the buffered one does not. This
    /// is the streamed side of "the upstream sent no id".
    @Test("an assembled streamed tool call with no id is given one")
    func assembledToolCallWithoutID() {
        let message = AssembledMessage(
            role: "assistant",
            content: "",
            toolCalls: [AssembledToolCall(index: 0, id: nil, name: "calculator", arguments: "{}")],
            finishReason: .toolCalls,
            usage: nil
        )
        guard case let .toolCall(call) = OpenRouterProvider.outcome(from: message) else {
            Issue.record("expected a tool call")
            return
        }
        #expect(!call.id.isEmpty, "a call with no id is given one rather than dropped")
        #expect(call.toolName == "calculator")
    }

    /// The usage a buffered reply reports, with the same three counters missing. This runs through
    /// `reportUsage`, which is a different function from the streamed accounting.
    @Test("a buffered reply with a partial usage envelope still records what it has")
    func bufferedUsageOmissions() async throws {
        let recorder = UsageRecorder()
        LocalStubURLProtocol.serve([
            .init(
                headers: ["Content-Type": "application/json"],
                body: Data(
                    #"{"id":"gen-1","choices":[{"finish_reason":"stop","message":{"content":"Hi"}}],"usage":{"cost":0.5}}"#.utf8
                )
            )
        ])
        let provider = OpenRouterProvider(
            configuration: OpenRouterConfiguration(apiKey: "sk-or-v1-test", streaming: false),
            session: LocalStubURLProtocol.session(),
            usageObserver: recorder
        )

        for try await _ in provider.stream(
            request: LLMRequest(messages: [LLMMessage(role: .user, content: "hi")])
        ) {}

        let usage = try #require(await recorder.mostRecent)
        #expect(usage.model == "openai/gpt-4o", "the configured model stands in")
        #expect(usage.promptTokens == 0)
        #expect(usage.completionTokens == 0)
        #expect(usage.reportedCostUSD == 0.5)
    }
}

// MARK: - Defaults inside the app's own logic

@Suite("Fallbacks inside the app")
struct AppFallbackTests {
    /// A route that matches but names no model. The route still decided *something* — it matched —
    /// and the default model is what answers, rather than the turn being sent nowhere.
    @Test("a matched route with no model in its metadata falls back to the default")
    func routeWithoutModelMetadata() async throws {
        let router = SemanticRouter()
        _ = try await router.register(
            SemanticRouterKit.Route(name: "greeting", utterances: ["hello there"], metadata: [:])
        )
        let pipeline = await PipelineFixture.make(router: router)
        var trace = PipelineTrace()
        let result = await pipeline.prepare(userText: "hello there", history: [], trace: &trace)

        guard case let .ready(turn) = result else {
            Issue.record("expected a ready turn, got \(result)")
            return
        }
        #expect(turn.modelID == PipelineSettings().defaultModelID)
        #expect(trace.outcome(for: .semanticRoute)?.summary.contains("greeting") == true)
    }

    /// Arguments that are not valid UTF-8 at all. The authority gate is asked with an empty string
    /// rather than being skipped — a call whose arguments cannot even be read is exactly the kind
    /// policy should get a look at, not the kind that should bypass it.
    @Test("tool arguments that are not text are still put to the authority gate")
    func unreadableToolArguments() async {
        let registry = ToolRegistryKit.ToolRegistry()
        await registry.register(DemoTools.calculator, handler: DemoTools.calculatorHandler())
        let round = ToolRoundTrip(
            registry: registry,
            gate: ToolAuthorityGate(
                capabilities: ToolAuthorityGate.readOnly(tools: [DemoTools.calculatorName])
            )
        )
        let resolution = await round.resolve(
            id: "call-1",
            toolName: DemoTools.calculatorName,
            argumentsJSON: Data([0xC3, 0x28]),
            in: ToolCallContext(conversationID: "conv-bytes", provenance: .modelAuthored)
        )

        // Authorized on an empty argument string, then rejected by the registry as invalid
        // arguments — which goes back to the model rather than being shown as a failure.
        #expect(resolution.records.first?.outcome.isRefusal == false)
        let dispatch = resolution.records.first { $0.stage == .toolDispatch }
        #expect(dispatch?.outcome.isFailure == false, "malformed arguments are model noise")
        #expect(resolution.observation != nil, "the model has to be told what went wrong")
    }

    /// OpenRouter sends `"arguments": ""` for a tool with no parameters, and empty bytes fail
    /// `JSONDecoder` outright. Bytes that are not text at all take the same path.
    @Test("argument bytes that are not text normalize to an empty object")
    func normalizingUnreadableArguments() {
        #expect(ToolRoundTrip.normalized(Data([0xC3, 0x28])) == Data("{}".utf8))
        #expect(ToolRoundTrip.normalized(Data("   ".utf8)) == Data("{}".utf8))
        #expect(ToolRoundTrip.normalized(Data(#"{"a":1}"#.utf8)) == Data(#"{"a":1}"#.utf8))
    }

    /// A tool argument the JSON encoder refuses. `Double.nan` is not representable in JSON, and
    /// `JSONEncoder` throws rather than writing something a decoder would misread — so the empty
    /// object is what the registry gets, and it answers `invalidArguments`.
    @Test("an argument JSON cannot represent becomes an empty object, not malformed bytes")
    func unencodableArgument() {
        let encoded = ProviderEffectExecutor.argumentsJSON(["value": .double(Double.nan)])
        #expect(encoded == Data("{}".utf8))

        let ordinary = ProviderEffectExecutor.argumentsJSON(["value": .double(2)])
        #expect(ordinary != Data("{}".utf8))
    }

    /// The send button's own condition. Both halves matter: a blank draft cannot be sent, and
    /// neither can a real one while a turn is already open.
    @Test("the send button is live only for a non-blank draft with nothing in flight")
    @MainActor
    func canSendNeedsBothHalves() async {
        let model = await ChatModelFixture.make()
        #expect(!model.canSend, "an empty draft cannot be sent")
        model.draft = "   \n "
        #expect(!model.canSend, "whitespace is not a message")
        model.draft = "what is the capital of France?"
        #expect(model.canSend, "a real draft with nothing in flight is sendable")
    }

    /// An `OSStatus` no human has ever seen. The number stays in the sentence whatever Security
    /// does with it — that is the part someone can look up, and the part a bug report needs.
    ///
    /// Security answers even for a made-up status ("OSStatus -999999"), which is why the `??`
    /// fallback in `KeychainError.description` has no test taking its right-hand side: on Darwin
    /// `SecCopyErrorMessageString` does not return nil. It stays because the API is declared
    /// optional and a force-unwrap here would trade a readable error for a crash.
    @Test("a Keychain status nobody has documented still names the number")
    func keychainStatusWithoutMessage() {
        let description = KeychainError.unexpectedStatus(-999_999).description
        #expect(description.contains("-999999"))
        #expect(description.hasPrefix("Keychain returned OSStatus"), "got \(description)")

        let known = KeychainError.unexpectedStatus(errSecItemNotFound).description
        #expect(known.contains("-25300"))
    }

    /// A key status with no `usage` at all — a fresh key that has never been charged. Rendering a
    /// blank there would read as an error rather than as zero.
    @Test("a key that has never been used renders zero rather than blank")
    @MainActor
    func keyStatusWithoutUsage() async {
        let status = OpenRouterKeyStatus(
            label: nil,
            usage: nil,
            limit: 10,
            limitRemaining: 10,
            isFreeTier: nil
        )
        #expect(status.remainingDescription == "$10.0000")
        #expect(!status.isExhausted)

        let source = StaticModelCatalog(keyStatus: status)
        await ViewRenderFixture.settle(
            NavigationStack { List { KeyStatusSection(source: source) } }
        )
    }

    /// Two models at the same price are ordered by slug, so the list does not shuffle between
    /// launches. A sort with no tie-break is a list that looks different every time it is opened.
    @Test("models priced identically are ordered by slug rather than arbitrarily")
    func equalPricesTieBreakOnSlug() {
        func model(_ id: String, prompt: String) -> OpenRouterModel {
            OpenRouterModel(
                id: id,
                name: nil,
                contextLength: 1_000,
                pricing: .init(prompt: prompt, completion: prompt, inputCacheRead: nil),
                architecture: nil,
                supportedParameters: nil,
                topProvider: nil
            )
        }
        let catalog = ModelCatalog(models: [
            model("vendor/zebra", prompt: "0.000001"),
            model("vendor/alpha", prompt: "0.000001"),
            model("vendor/cheap", prompt: "0.0000001")
        ])
        #expect(catalog.selectable.map(\.id) == ["vendor/cheap", "vendor/alpha", "vendor/zebra"])
    }

    /// Every origin has to say what "Delete key" will actually do, and the four answers are not
    /// interchangeable — the build-configuration one is the only one that warns the key comes back.
    @Test("every secret origin explains what deleting the key would mean")
    func everyOriginHasAKeyManagementNote() {
        let notes = SecretOriginFixture.all.map(\.keyManagementNote)
        #expect(notes.allSatisfy { !$0.isEmpty })
        #expect(
            SecretOrigin.buildConfiguration.keyManagementNote.contains("come back"),
            "the one origin where deleting does not stick has to say so"
        )
        #expect(SecretOrigin.testHarness.keyManagementNote.contains("launch argument"))
        #expect(
            SecretOrigin.keychain.keyManagementNote == SecretOrigin.absent.keyManagementNote,
            "an absent key and a stored one are managed the same way"
        )
        #expect(Set(notes).count == 3, "three distinct notes across four origins")
    }
}

// MARK: - Fixtures

enum SecretOriginFixture {
    static let all: [SecretOrigin] = [.keychain, .buildConfiguration, .testHarness, .absent]
}

enum PipelineFixture {
    static func make(router: SemanticRouter) async -> PreModelPipeline {
        let prompts = PromptRegistry()
        _ = try? await prompts.register(name: "chat.system", template: "You are terse.")
        return PreModelPipeline(
            prompts: prompts,
            guardrail: GuardrailPipeline(policy: GuardrailPolicy()),
            router: router,
            cache: ResponseCache(capacity: 4),
            memory: MemoryStore(),
            retriever: Retriever(embedder: HashingEmbeddingProvider()),
            compactor: ContextCompactor(strategies: [SlidingWindowCompactionStrategy()])
        )
    }
}

@MainActor
enum ChatModelFixture {
    /// A view model whose transport is never reached. `canSend` is decided before anything is
    /// sent, so the provider only has to exist.
    static func make() async -> ChatViewModel {
        let usage = UsageRecorder()
        let scopes = BudgetScopes(
            account: ScopeID("account"),
            conversation: ScopeID("conversation")
        )
        let governor = QuotaGovernor()
        try? await governor.register(scopes.account, at: 0)
        try? await governor.register(scopes.conversation, under: scopes.account, at: 0)
        return ChatViewModel(
            pipeline: await PipelineFixture.make(router: SemanticRouter()),
            executor: TurnExecutor(
                provider: OpenRouterProvider(
                    configuration: OpenRouterConfiguration(apiKey: "sk-or-v1-test"),
                    session: OfflineURLProtocol.session(),
                    usageObserver: usage
                ),
                idempotency: IdempotencyGuard(),
                profiler: WorkloadProfiler(),
                estimator: CostEstimator(priceBook: TestPriceBook.empty),
                governor: governor,
                retryPolicy: ExponentialBackoffRetryPolicy(maxAttempts: 1),
                meter: TokenMeter(registry: PricingRegistry()),
                usage: usage,
                scopes: scopes
            ),
            review: PostModelPipeline(guardrail: GuardrailPipeline(policy: GuardrailPolicy()))
        )
    }
}

@MainActor
enum ViewRenderFixture {
    static func settle(_ view: some View, passes: Int = 16) async {
        let host = UIHostingController(rootView: AnyView(view))
        host.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let window = UIWindow(frame: host.view.frame)
        window.rootViewController = host
        window.isHidden = false
        for _ in 0..<passes {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            await Task.yield()
            try? await Task.sleep(nanoseconds: 4_000_000)
        }
        window.isHidden = true
    }
}

// MARK: - Retries and empty requests

@Suite("Effect executor — backing off and starting from nothing", .serialized)
struct EffectRetryTests {
    private func executor(maxAttempts: Int, messages: [LLMMessage]) -> ProviderEffectExecutor {
        ProviderEffectExecutor(
            provider: OpenRouterProvider(
                configuration: OpenRouterConfiguration(apiKey: "sk-or-v1-test", streaming: true),
                session: LocalStubURLProtocol.session(),
                usageObserver: UsageRecorder()
            ),
            request: LLMRequest(messages: messages),
            retryPolicy: ExponentialBackoffRetryPolicy(maxAttempts: maxAttempts),
            onDelta: { _ in }
        )
    }

    private static let answer = "data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"},"
        + "\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"

    /// A 429 with a `Retry-After` is the one failure that carries a delay from the server, and
    /// honouring it rather than the policy's own schedule is the difference between backing off
    /// and hammering a rate limit until the key is throttled harder.
    @Test("a rate limit is waited out and the next attempt succeeds")
    func retriesAfterARateLimit() async throws {
        LocalStubURLProtocol.serve([
            .init(
                statusCode: 429,
                headers: ["Content-Type": "application/json", "Retry-After": "1"],
                body: Data(OpenRouterTestFixtures.rateLimitedBody.utf8)
            ),
            .init(body: Data(Self.answer.utf8))
        ])
        let subject = executor(
            maxAttempts: 3,
            messages: [LLMMessage(role: .user, content: "hi")]
        )

        let result = try await subject.perform(
            EffectPayload(action: "chat.completion", fields: [:])
        )
        #expect(result.body == "Hi")
        #expect(await subject.attemptsMade() == 2, "the first attempt was rate limited")
        #expect(result.metadata["attempts"] == "2")
    }

    /// A request with no messages at all. The agent transcript records the prompt it answered, and
    /// there is nothing to record here — an empty string is the honest entry, and it must not be a
    /// crash on the way to one.
    @Test("a request carrying no messages still produces a transcript")
    func requestWithNoMessages() async throws {
        LocalStubURLProtocol.serve(sse: Self.answer)
        let subject = executor(maxAttempts: 1, messages: [])

        let result = try await subject.perform(
            EffectPayload(action: "chat.completion", fields: [:])
        )
        #expect(result.body == "Hi")
        let records = await subject.toolRecords()
        #expect(records.contains { $0.stage == .agentLoop })
    }
}

@Suite("The credit section with everything filled in")
@MainActor
struct KeyStatusRowTests {
    /// A key that is labelled, funded, spent out and on a paid tier — every row the section can
    /// draw, including the exhausted warning that the unlimited fixture never reaches.
    @Test("a labelled, exhausted, paid key draws every row it has")
    func fullyPopulatedStatus() async {
        let status = OpenRouterKeyStatus(
            label: "sk-or-v1-live…9f2c",
            usage: 12.5,
            limit: 12.5,
            limitRemaining: 0,
            isFreeTier: false
        )
        #expect(status.isExhausted)
        #expect(status.remainingDescription == "$0.0000")

        await ViewRenderFixture.settle(
            NavigationStack { List { KeyStatusSection(source: StaticModelCatalog(keyStatus: status)) } }
        )
    }
}
