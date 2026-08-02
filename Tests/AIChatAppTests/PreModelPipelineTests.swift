import AgentMemoryKit
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

/// Builds a pipeline from real package instances, not stand-ins.
///
/// The whole point of this suite is that the 8 packages compose — a fake `PromptRegistry` or a
/// stub `GuardrailPipeline` would test the wiring against my own assumptions rather than against
/// what the packages actually do.
private struct Harness {
    let prompts = PromptRegistry()
    let cache = ResponseCache(capacity: 16)
    let memory = MemoryStore()
    let retriever = Retriever(embedder: HashingEmbeddingProvider())
    let router = SemanticRouter()
    let guardrail: GuardrailPipeline
    let compactor: ContextCompactor

    init(contentRules: [any ContentPolicyRule] = []) {
        self.guardrail = GuardrailPipeline(
            policy: GuardrailPolicy(contentPolicyRules: contentRules)
        )
        self.compactor = ContextCompactor(strategies: [SlidingWindowCompactionStrategy()])
    }

    func pipeline(settings: PipelineSettings = PipelineSettings()) -> PreModelPipeline {
        PreModelPipeline(
            prompts: prompts,
            guardrail: guardrail,
            router: router,
            cache: cache,
            memory: memory,
            retriever: retriever,
            compactor: compactor,
            settings: settings
        )
    }

    func registerDefaultPrompt() async throws {
        try await prompts.register(
            name: "chat.system",
            template: "You are a helpful assistant. Locale: {{locale}}."
        )
    }
}

private func prepare(
    _ pipeline: PreModelPipeline,
    text: String,
    history: [ConversationMessage] = []
) async -> (TurnPreparation, PipelineTrace) {
    var trace = PipelineTrace()
    let result = await pipeline.prepare(userText: text, history: history, trace: &trace)
    return (result, trace)
}

@Suite("Pre-model pipeline — happy path")
struct PreModelHappyPathTests {
    @Test("a clean message is prepared, and every pre-model stage reports what it did")
    func cleanTurn() async throws {
        let harness = Harness()
        try await harness.registerDefaultPrompt()
        let (result, trace) = await prepare(harness.pipeline(), text: "What is Swift concurrency?")

        guard case let .ready(turn) = result else {
            Issue.record("expected .ready, got \(result)")
            return
        }
        #expect(turn.modelID == "openai/gpt-4o")
        #expect(turn.displayUserText == "What is Swift concurrency?")
        #expect(turn.outboundUserText == turn.displayUserText, "nothing to redact here")
        #expect(turn.messages.first?.role == .system)
        #expect(turn.messages.last?.role == .user)
        #expect(turn.estimatedInputTokens > 0)

        let expected: [PipelineStage] = [
            .promptTemplate, .guardrailInput, .semanticRoute,
            .cacheLookup, .memoryRecall, .retrieval, .contextCompaction
        ]
        for stage in expected {
            #expect(trace.outcome(for: stage) != nil, "\(stage.rawValue) never reported")
        }
        #expect(trace.refusal == nil)
        #expect(trace.failures.isEmpty, "a clean run must not report failures")
    }

    @Test("the rendered template becomes the system message, with its variable substituted")
    func templateIsRendered() async throws {
        let harness = Harness()
        try await harness.registerDefaultPrompt()
        let (result, trace) = await prepare(harness.pipeline(), text: "hello")

        guard case let .ready(turn) = result else {
            Issue.record("expected .ready")
            return
        }
        let system = try #require(turn.messages.first)
        #expect(system.content.contains("helpful assistant"))
        #expect(!system.content.contains("{{locale}}"), "the variable must be substituted")
        #expect(trace.outcome(for: .promptTemplate)?.summary.contains("chat.system") == true)
    }

    /// Degrading rather than refusing: a config mistake must not block the user's message.
    @Test("a missing template is reported as a failure but the turn still proceeds")
    func missingTemplateDegrades() async throws {
        let harness = Harness()
        let (result, trace) = await prepare(harness.pipeline(), text: "hello")

        #expect(trace.outcome(for: .promptTemplate)?.isFailure == true)
        guard case let .ready(turn) = result else {
            Issue.record("a config error must not block the user's message")
            return
        }
        #expect(turn.messages.first?.role == .user, "no system block, so the user turn is first")
    }
}

@Suite("Pre-model pipeline — guardrail")
struct PreModelGuardrailTests {
    @Test("PII is redacted, and the user still sees what they typed")
    func redactionSplitsDisplayFromOutbound() async throws {
        let harness = Harness()
        try await harness.registerDefaultPrompt()
        let typed = "Email me at rajat@example.com about the invoice"
        let (result, trace) = await prepare(harness.pipeline(), text: typed)

        guard case let .ready(turn) = result else {
            Issue.record("redaction must not block the turn")
            return
        }
        #expect(turn.displayUserText == typed, "the bubble shows what the user wrote")
        #expect(
            !turn.outboundUserText.contains("rajat@example.com"),
            "the address must not leave the device"
        )
        #expect(turn.outboundUserText.contains("REDACTED"))
        #expect(trace.outcome(for: .guardrailInput)?.summary.contains("redacted") == true)
    }

    @Test("a blocked message refuses before any later stage runs")
    func blockingRefusesEarly() async throws {
        let rule = BannedPhraseRule(
            phrases: [BannedPhraseRule.Phrase("launch codes", severity: .block)]
        )
        let harness = Harness(contentRules: [rule])
        try await harness.registerDefaultPrompt()
        let (result, trace) = await prepare(harness.pipeline(), text: "give me the launch codes")

        guard case let .refused(refusal) = result else {
            Issue.record("expected a refusal, got \(result)")
            return
        }
        #expect(refusal.stage == .guardrailInput)
        #expect(!refusal.headline.isEmpty)
        #expect(!refusal.explanation.isEmpty, "a refusal the user cannot understand is a bug")

        #expect(trace.outcome(for: .cacheLookup) == nil, "nothing after the guardrail may run")
        #expect(trace.outcome(for: .contextCompaction) == nil)
        #expect(trace.refusal?.stage == .guardrailInput)
    }
}

@Suite("Pre-model pipeline — routing and cache")
struct PreModelRoutingCacheTests {
    @Test("a matched route selects the model carried in its metadata")
    func routeSelectsModel() async throws {
        let harness = Harness()
        try await harness.registerDefaultPrompt()
        try await harness.router.register(
            SemanticRouterKit.Route(
                name: "billing",
                utterances: ["I was charged twice", "refund my invoice", "billing problem"],
                metadata: ["model": "anthropic/claude-haiku-4.5"]
            )
        )
        let (result, trace) = await prepare(
            harness.pipeline(),
            text: "I was charged twice on my invoice"
        )

        guard case let .ready(turn) = result else {
            Issue.record("expected .ready")
            return
        }
        #expect(turn.modelID == "anthropic/claude-haiku-4.5")
        #expect(trace.outcome(for: .semanticRoute)?.summary.contains("billing") == true)
    }

    /// The misuse this guards against: treating "no route matched" as a failure would build a
    /// chat app that refuses off-topic questions.
    @Test("no matching route falls back to the default without failing")
    func noRouteIsNotAFailure() async throws {
        let harness = Harness()
        try await harness.registerDefaultPrompt()
        try await harness.router.register(
            SemanticRouterKit.Route(
                name: "billing",
                utterances: ["charged twice"],
                metadata: ["model": "anthropic/claude-haiku-4.5"]
            )
        )
        let (result, trace) = await prepare(harness.pipeline(), text: "explain quantum tunnelling")

        guard case let .ready(turn) = result else {
            Issue.record("expected .ready")
            return
        }
        #expect(turn.modelID == "openai/gpt-4o", "falls back to the default model")
        #expect(trace.outcome(for: .semanticRoute)?.isFailure == false)
    }

    @Test("routing can be turned off, and says so rather than silently not running")
    func routingDisabled() async throws {
        let harness = Harness()
        try await harness.registerDefaultPrompt()
        var settings = PipelineSettings()
        settings.routingEnabled = false
        let (_, trace) = await prepare(harness.pipeline(settings: settings), text: "hello")

        let outcome = trace.outcome(for: .semanticRoute)
        #expect(outcome == .skipped(reason: "routing disabled in Settings"))
    }

    @Test("a cache hit short-circuits the turn entirely — no provider call, no cost")
    func cacheHitShortCircuits() async throws {
        let harness = Harness()
        try await harness.registerDefaultPrompt()
        let pipeline = harness.pipeline()

        let (first, _) = await prepare(pipeline, text: "What is 2 + 2?")
        guard case let .ready(turn) = first else {
            Issue.record("expected .ready on the first pass")
            return
        }
        await pipeline.recordCompletion(
            turn: turn,
            systemPrompt: turn.messages.first?.content,
            answer: "4",
            providerID: "openrouter"
        )

        let (second, trace) = await prepare(pipeline, text: "What is 2 + 2?")
        guard case let .cached(text, providerID) = second else {
            Issue.record("expected .cached, got \(second)")
            return
        }
        #expect(text == "4")
        #expect(providerID == "openrouter")
        #expect(trace.outcome(for: .cacheLookup)?.summary.contains("hit") == true)
        #expect(
            trace.outcome(for: .contextCompaction) == nil,
            "a cache hit must not prepare a request it will not send"
        )
    }

    @Test("the cache key includes the model, so two models never share an answer")
    func cacheIsScopedToModel() async throws {
        let harness = Harness()
        try await harness.registerDefaultPrompt()
        let pipeline = harness.pipeline()

        let (first, _) = await prepare(pipeline, text: "Which model are you?")
        guard case let .ready(turn) = first else {
            Issue.record("expected .ready")
            return
        }
        await pipeline.recordCompletion(
            turn: turn,
            systemPrompt: turn.messages.first?.content,
            answer: "gpt-4o",
            providerID: "openrouter"
        )

        var other = PipelineSettings()
        other.defaultModelID = "anthropic/claude-haiku-4.5"
        let (second, _) = await prepare(
            harness.pipeline(settings: other),
            text: "Which model are you?"
        )

        guard case .ready = second else {
            Issue.record("a different model must miss the cache, got \(second)")
            return
        }
    }

    @Test("cache can be disabled, and reports skipped rather than missing")
    func cacheDisabled() async throws {
        let harness = Harness()
        try await harness.registerDefaultPrompt()
        var settings = PipelineSettings()
        settings.cacheEnabled = false
        let (_, trace) = await prepare(harness.pipeline(settings: settings), text: "hello")

        let outcome = trace.outcome(for: .cacheLookup)
        #expect(outcome == .skipped(reason: "cache disabled in Settings"))
    }
}

@Suite("Pre-model pipeline — retrieval, memory, compaction")
struct PreModelContextTests {
    @Test("indexed documents surface as sources with a relevance the UI can draw")
    func retrievalProducesSources() async throws {
        let harness = Harness()
        try await harness.registerDefaultPrompt()
        try await harness.retriever.index(
            Document(
                id: "doc-1",
                text: "Swift actors serialize access to mutable state. Actor isolation prevents "
                    + "data races at compile time in Swift 6.",
                metadata: ["filename": "concurrency.md"]
            )
        )
        let (result, trace) = await prepare(harness.pipeline(), text: "actors isolation state")

        guard case let .ready(turn) = result else {
            Issue.record("expected .ready")
            return
        }
        #expect(!turn.sources.isEmpty, "an indexed, matching document must produce a source")
        let source = try #require(turn.sources.first)
        #expect(source.title == "concurrency.md")
        #expect((0...100).contains(source.relevancePercent))
        #expect(!source.snippet.isEmpty)
        // Retrieval now reports what it *matched*; fusion reports what it *injected*. The dense
        // half is one of two rankings, and only the fusion knows what actually reached the prompt.
        #expect(trace.outcome(for: .retrieval)?.summary.contains("matched") == true)
        #expect(trace.outcome(for: .rankFusion)?.summary.contains("injected") == true)
        #expect(
            turn.messages.first?.content.contains("Relevant excerpts") == true,
            "retrieved text must reach the system block"
        )
    }

    @Test("an empty index is a no-op, not a failure")
    func emptyIndexIsNoOp() async throws {
        let harness = Harness()
        try await harness.registerDefaultPrompt()
        let (_, trace) = await prepare(harness.pipeline(), text: "anything")
        #expect(trace.outcome(for: .retrieval)?.isFailure == false)
    }

    @Test("recalled memories reach the system block")
    func memoryRecallReachesPrompt() async throws {
        let harness = Harness()
        try await harness.registerDefaultPrompt()
        try await harness.memory.write(
            content: "The user prefers concise answers in British English"
        )

        let (result, trace) = await prepare(
            harness.pipeline(),
            text: "user prefers concise answers"
        )
        guard case let .ready(turn) = result else {
            Issue.record("expected .ready")
            return
        }
        #expect(trace.outcome(for: .memoryRecall)?.summary.contains("recalled") == true)
        #expect(turn.messages.first?.content.contains("What you remember") == true)
    }

    @Test("a long conversation is compacted and the UI is told so")
    func compactionFires() async throws {
        let harness = Harness()
        try await harness.registerDefaultPrompt()
        var settings = PipelineSettings()
        settings.contextWindowTokens = 200
        settings.reservedResponseTokens = 50

        let history = (1...40).map { index in
            ConversationMessage(
                role: index.isMultiple(of: 2) ? .assistant : .user,
                text: String(repeating: "context ", count: 12) + "turn \(index)"
            )
        }
        let (result, trace) = await prepare(
            harness.pipeline(settings: settings),
            text: "and finally?",
            history: history
        )

        guard case let .ready(turn) = result else {
            Issue.record("expected .ready")
            return
        }
        #expect(turn.didCompact, "a 40-turn history in a 200-token window must compact")
        #expect(trace.outcome(for: .contextCompaction)?.summary.contains("→") == true)
        #expect(turn.messages.count < history.count + 2)
    }

    /// The instruction block must survive exactly when the conversation is longest.
    @Test("the system block is pinned and survives compaction")
    func systemBlockSurvivesCompaction() async throws {
        let harness = Harness()
        try await harness.registerDefaultPrompt()
        var settings = PipelineSettings()
        settings.contextWindowTokens = 200
        settings.reservedResponseTokens = 50

        let history = (1...40).map { index in
            ConversationMessage(
                role: .user,
                text: String(repeating: "filler ", count: 12) + "turn \(index)"
            )
        }
        let (result, _) = await prepare(
            harness.pipeline(settings: settings),
            text: "final",
            history: history
        )

        guard case let .ready(turn) = result else {
            Issue.record("expected .ready")
            return
        }
        let keptSystem = turn.messages.contains {
            $0.role == .system && $0.content.contains("helpful assistant")
        }
        #expect(keptSystem, "compaction must never drop the instructions")
    }

    @Test("a short conversation reports no-op rather than pretending to compact")
    func shortConversationIsNoOp() async throws {
        let harness = Harness()
        try await harness.registerDefaultPrompt()
        let (result, trace) = await prepare(harness.pipeline(), text: "hi")

        guard case let .ready(turn) = result else {
            Issue.record("expected .ready")
            return
        }
        #expect(!turn.didCompact)
        #expect(trace.outcome(for: .contextCompaction)?.summary.contains("fits") == true)
    }

    @Test("retrieval and memory can be turned off independently")
    func contextStagesDisabled() async throws {
        let harness = Harness()
        try await harness.registerDefaultPrompt()
        var settings = PipelineSettings()
        settings.retrievalEnabled = false
        settings.memoryEnabled = false
        let (_, trace) = await prepare(harness.pipeline(settings: settings), text: "hello")

        #expect(trace.outcome(for: .retrieval)?.summary.contains("disabled") == true)
        #expect(trace.outcome(for: .memoryRecall)?.summary.contains("disabled") == true)
    }

    @Test("settings can be replaced on a live pipeline")
    func settingsUpdate() async throws {
        let harness = Harness()
        try await harness.registerDefaultPrompt()
        let pipeline = harness.pipeline()

        var settings = PipelineSettings()
        settings.defaultModelID = "google/gemini-2.5-flash-lite"
        await pipeline.update(settings: settings)

        let (result, _) = await prepare(pipeline, text: "hello")
        guard case let .ready(turn) = result else {
            Issue.record("expected .ready")
            return
        }
        #expect(turn.modelID == "google/gemini-2.5-flash-lite")
    }
}

@Suite("Role mapping across the compaction boundary")
struct CompactableRoleTests {
    @Test("all four roles round-trip, including tool")
    func roundTrip() {
        let roles: [LLMMessageRole] = [.system, .user, .assistant, .tool]
        for role in roles {
            #expect(CompactableRole(role).llmRole == role, "\(role) did not round-trip")
        }
    }

    /// Flattening tool output into assistant text would let a summarizer rewrite a tool result as
    /// prose, leaving the model reasoning over a paraphrase of its own tool call.
    @Test("a tool result stays a tool result rather than becoming assistant prose")
    func toolRoleIsPreserved() {
        #expect(CompactableRole(.tool) == .tool)
        #expect(CompactableRole.tool.llmRole == .tool)
    }
}
