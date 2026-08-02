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
import SchemaMigrationKit
import SemanticRouterKit
import TokenMeterKit
import ToolRegistryKit
import WorkloadProfilerKit

/// Builds the object graph.
///
/// One place where every package is constructed and handed its collaborators, so the wiring can be
/// read in one sitting and the views never construct anything themselves. It is also the only
/// place that knows the app's defaults — prompt text, routes, budget ceilings — which keeps those
/// decisions out of the pipeline, where they would look like behaviour rather than configuration.
struct Composition: Sendable {
    let pipeline: PreModelPipeline
    let executor: TurnExecutor
    let review: PostModelPipeline
    let usage: UsageRecorder
    let meter: TokenMeter
    let registry: PricingRegistry
    let catalog: any ModelCatalogProviding
    let tools: ToolRoundTrip
    let metadata: MetadataPipeline
    /// The reasoning effort the next request carries. Written when a conversation opens and when
    /// the user changes it; read by the provider as it builds the body.
    let effort: ReasoningEffortBox

    /// Builds the graph.
    ///
    /// `onSettled` receives the integer microcents each finished turn really cost, so the app can
    /// keep the month's total across launches — `QuotaGovernor`'s own ledger is in memory and
    /// cannot.
    static func build(
        apiKey: String,
        secrets: AppSecrets,
        budget: MonthlyBudget = MonthlyBudget(),
        arguments: [String] = ProcessInfo.processInfo.arguments,
        onSettled: @escaping @Sendable (Int) -> Void = { _ in }
    ) async -> Composition {
        let usage = UsageRecorder()
        let registry = PricingRegistry()
        let meter = TokenMeter(registry: registry)
        let configuration = OpenRouterConfiguration(
            apiKey: apiKey,
            siteURL: secrets.siteURL,
            appName: secrets.appName
        )

        let effort = ReasoningEffortBox()
        let pipeline = await makePipeline(configuration: configuration)
        let scopes = BudgetScopes(
            account: ScopeID("account"),
            conversation: ScopeID("conversation")
        )
        let governor = await makeGovernor(scopes: scopes, budget: budget)
        let tools = await makeTools()

        let executor = TurnExecutor(
            provider: OpenRouterProvider(
                configuration: configuration,
                session: .shared,
                usageObserver: usage,
                effort: effort
            ),
            idempotency: IdempotencyGuard(),
            profiler: WorkloadProfiler(),
            estimator: CostEstimator(priceBook: Self.emptyPriceBook),
            governor: governor,
            retryPolicy: ExponentialBackoffRetryPolicy(maxAttempts: 3),
            meter: meter,
            usage: usage,
            scopes: scopes,
            tools: tools,
            budget: budget,
            onSettled: onSettled
        )

        return Composition(
            pipeline: pipeline,
            executor: executor,
            review: PostModelPipeline(guardrail: GuardrailPipeline(policy: GuardrailPolicy())),
            usage: usage,
            meter: meter,
            registry: registry,
            catalog: makeCatalog(configuration: configuration, arguments: arguments),
            tools: tools,
            metadata: await makeMetadata(configuration: configuration),
            effort: effort
        )
    }

    /// A view model bound to one stored thread.
    ///
    /// Here rather than in the view because it is the last place that knows every actor the model
    /// needs; a view assembling five collaborators is a view that has to be changed whenever the
    /// graph is.
    @MainActor
    func makeChatViewModel(
        conversation: Conversation,
        onPersist: @escaping @MainActor ([StoredMessage], String) -> Void
    ) -> ChatViewModel {
        ChatViewModel(
            conversationID: conversation.id.uuidString,
            pipeline: pipeline,
            executor: executor,
            review: review,
            metadata: metadata,
            tools: tools,
            // A message with no recorded time is dated to the thread's own start rather than to
            // now: it is approximate, but it never claims a two-year-old message arrived today.
            seed: conversation.messages.map {
                StoredMessage(
                    id: $0.id,
                    role: $0.role,
                    text: $0.text,
                    createdAt: $0.createdAt ?? conversation.createdAt
                )
            },
            title: conversation.title == Conversation.untitled
                ? ChatViewModel.untitled
                : conversation.title,
            onPersist: onPersist
        )
    }

    /// The real client, or a fixed catalog when a UI test asked for one.
    ///
    /// A XCUITest launches the app as its own process with no test code linked, so `URLProtocol`
    /// stubbing — which the unit tests use — cannot reach it. The choice has to be made inside the
    /// app, on the same launch argument that already swaps the Keychain and biometrics.
    private static func makeCatalog(
        configuration: OpenRouterConfiguration,
        arguments: [String]
    ) -> any ModelCatalogProviding {
        guard arguments.contains("-UITestMode") else {
            return ModelCatalogClient(configuration: configuration)
        }
        return StaticModelCatalog()
    }

    /// The pipeline that names conversations and suggests what to ask next.
    ///
    /// Its own model and its own configuration: the metadata asks are small, structured and
    /// frequent, and routing them to whatever expensive model is answering the user would double
    /// the cost of every turn for a navigation-bar caption.
    private static func makeMetadata(
        configuration: OpenRouterConfiguration
    ) async -> MetadataPipeline {
        var metadataConfiguration = configuration
        metadataConfiguration.model = MetadataPipeline.defaultModelID
        return MetadataPipeline(
            completer: OpenRouterMetadataCompleter(configuration: metadataConfiguration),
            contracts: await makeContracts()
        )
    }

    /// The versioned metadata contract, registered exactly once for the process.
    ///
    /// `SchemaRegistry.register` throws on a second call for the same contract, which is why this
    /// lives here and never in a SwiftUI `.task` — that re-runs on identity change and would take
    /// the whole feature down on a view redraw.
    ///
    /// `build` is a parameter, and not private, so the bootstrap failure below can be exercised.
    /// It is the branch that decides the app launches at all when the schema layer does not, and
    /// asserting it by reasoning rather than by running it would be a guess.
    static func makeContracts(
        _ build: () async throws -> SchemaRegistry = { try await MetadataSchema.makeRegistry() }
    ) async -> SchemaRegistry {
        do {
            return try await build()
        } catch {
            // A registry that failed to bootstrap still answers: every lookup throws
            // `.unknownContract`, the migration stage records `.failed`, and the conversation
            // gets a fallback title. That is a better launch than trapping over a caption.
            return SchemaRegistry()
        }
    }

    /// The tools the model may call, and the authority that decides whether it actually may.
    ///
    /// Registration is an `await` during composition rather than a synchronous property
    /// initializer because `ToolRegistry` is an actor: registering after the first send has
    /// started would come back as `.unknownTool` for a tool that is plainly there.
    private static func makeTools() async -> ToolRoundTrip {
        let registry = ToolRegistryKit.ToolRegistry()
        await registry.register(DemoTools.calculator, handler: DemoTools.calculatorHandler())
        await registry.register(DemoTools.currentTime, handler: DemoTools.currentTimeHandler())
        return ToolRoundTrip(
            registry: registry,
            gate: ToolAuthorityGate(
                capabilities: ToolAuthorityGate.readOnly(
                    tools: [DemoTools.calculatorName, DemoTools.clockName]
                )
            )
        )
    }

    /// Which embedder retrieval and routing run on, decided once here.
    ///
    /// Once, and never per call: `HashingEmbeddingProvider` and `OpenRouterEmbeddingProvider`
    /// produce different vector widths, and `Embedding.cosineSimilarity` returns `0` on a
    /// dimension mismatch instead of throwing. An index that had mixed the two would score every
    /// passage identically and read as poor retrieval rather than as a defect, so the choice is
    /// made at composition from whether a key exists and never revisited inside a turn.
    ///
    /// `nil` configuration, or one with no key, keeps the bag-of-words embedder — which is a
    /// working configuration, just a blunt one, and strictly better than a provider that throws on
    /// every passage.
    static func makeEmbedder(
        configuration: OpenRouterConfiguration?
    ) -> any EmbeddingProvider {
        guard let configuration, OpenRouterEmbeddingProvider.isUsable(configuration) else {
            return HashingEmbeddingProvider()
        }
        return OpenRouterEmbeddingProvider(configuration: configuration)
    }

    /// Loads the corpus into both halves of retrieval.
    ///
    /// Both, from one source, deliberately: reciprocal-rank fusion combines *orderings*, so two
    /// halves indexing different document sets would still produce a confident-looking ranking
    /// over a corpus neither of them actually holds.
    static func makeLexicalIndex() async -> LexicalIndex? {
        let index = LexicalIndex()
        do {
            try await index.seed()
            return index
        } catch {
            // Retrieval degrades to dense-only, and the lexical stage records itself as skipped.
            // Refusing to launch a chat app because a help corpus did not load would be worse.
            return nil
        }
    }

    /// The pre-model half of the graph, with its corpus, prompt and routing table seeded.
    private static func makePipeline(
        configuration: OpenRouterConfiguration? = nil
    ) async -> PreModelPipeline {
        let retriever = Retriever(embedder: makeEmbedder(configuration: configuration))
        for document in AppKnowledge.retrievalDocuments {
            // A passage that fails to embed is dropped rather than fatal: the lexical half still
            // finds it, which is most of why there are two halves.
            try? await retriever.index(document)
        }
        let lexical = await makeLexicalIndex()
        let prompts = PromptRegistry()
        // Both registrations return a value this call site has no use for. Discarding it
        // explicitly rather than leaving `try?` unused keeps the build warning-free, and a
        // warning that is tolerated once is a warning nobody reads afterwards.
        _ = try? await prompts.register(name: "chat.system", template: systemTemplate)

        let router = SemanticRouter()
        for route in routes {
            _ = try? await router.register(route)
        }

        return PreModelPipeline(
            prompts: prompts,
            guardrail: GuardrailPipeline(policy: GuardrailPolicy()),
            router: router,
            cache: ResponseCache(capacity: 200),
            memory: MemoryStore(),
            retriever: retriever,
            lexical: lexical,
            compactor: ContextCompactor(strategies: [SlidingWindowCompactionStrategy()])
        )
    }

    /// The budget ledger, with both scopes registered.
    ///
    /// Unlimited by default: a demo that refuses on its third message because of a ceiling nobody
    /// chose teaches the wrong lesson about the budget layer. Settings sets a real one.
    ///
    /// Not private: the fallback below is the branch that keeps the app usable when the ledger
    /// cannot be built, and the only way to reach it is to hand this function scopes the governor
    /// rejects — which the composition root, by construction, never does.
    static func makeGovernor(
        scopes: BudgetScopes,
        budget: MonthlyBudget
    ) async -> QuotaGovernor {
        guard let governor = await TurnExecutor.makeGovernor(scopes: scopes, budget: budget) else {
            // The ceiling was rejected. An unlimited ledger is the honest fallback — pretending to
            // enforce a limit the governor refused to accept would be worse than not enforcing it.
            let fallback = QuotaGovernor()
            try? await fallback.register(scopes.account, at: 0)
            try? await fallback.register(scopes.conversation, under: scopes.account, at: 0)
            return fallback
        }
        return governor
    }

    /// An empty price book. `PriceBook([])` cannot actually throw — the only error is a duplicate
    /// model, and there are no entries — but the initializer is `throws`, so this names the
    /// fallback rather than force-trying it at a call site. Prices are installed later, from the
    /// live catalogue, into `PricingRegistry` rather than into this book.
    private static let emptyPriceBook: PriceBook = {
        guard let book = try? PriceBook([]) else {
            preconditionFailure("an empty price book cannot fail to build")
        }
        return book
    }()

    /// Loads the live catalog and registers every price.
    ///
    /// Called after the first screen is up rather than before it: the app is usable without the
    /// catalog, and blocking launch on a network call to populate a price table would trade a real
    /// cost for a cosmetic one. Until it lands, costs read as "not reported" rather than as zero.
    @discardableResult
    func installPricing() async -> Int {
        guard let fetched = try? await catalog.fetchCatalog() else { return 0 }
        return await fetched.installPricing(into: registry)
    }

    /// The tool sentence is not decoration. A model given a `tools` array still answers arithmetic
    /// from memory unless it is told not to, and "guessed 84" and "computed 84" are the same
    /// string right up until the numbers get bigger.
    private static let systemTemplate = """
        You are AI Chat, a concise assistant running inside an iOS app.
        Answer directly. Use markdown for structure when it genuinely helps.
        Call the calculator tool for any arithmetic and the current_time tool for the date
        or time, rather than answering from memory. Report tool results in your own words.
        Locale: {{locale}}.
        """

    /// The routing table. `metadata["model"]` is the slug the turn is sent to.
    ///
    /// Seeded with the literal words users type, because the bundled embedder is bag-of-words:
    /// synonyms score zero, so "my card was declined" has to share vocabulary with the route or it
    /// silently falls through to the default.
    private static var routes: [SemanticRouterKit.Route] {
        [
            SemanticRouterKit.Route(
                name: "code",
                utterances: [
                    "write a function", "fix this bug", "refactor this code",
                    "swift compile error", "unit test for"
                ],
                metadata: ["model": "openai/gpt-4o"]
            ),
            SemanticRouterKit.Route(
                name: "quick",
                utterances: ["hello", "hi", "thanks", "thank you", "good morning"],
                metadata: ["model": "google/gemini-2.5-flash-lite"]
            )
        ]
    }
}

extension Composition: SettingsApplying {
    /// Pushes one settings change into the actors that act on it.
    ///
    /// Three different destinations, and the order between them does not matter — none of these
    /// values is read by more than one actor. What does matter is that the ceiling goes to
    /// `setBudget` rather than being installed here: replacing the ledger while a send is in
    /// flight would orphan its reservation, and the executor is the only thing that knows whether
    /// one is open.
    func apply(_ snapshot: SettingsSnapshot) async {
        await pipeline.update(settings: snapshot.pipeline)
        await executor.update(snapshot.turn)
        await executor.setBudget(snapshot.budget)
        // Revokes and re-issues every open grant when it changes, because capabilities are frozen
        // into a `Grant` at issue time — so this has to reach the gate, not just the settings blob.
        await tools.setApprovalRequired(snapshot.pipeline.toolApprovalRequired)
    }
}
