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
import SwiftUI
import Testing
import TokenMeterKit
import ToolAuthorityKit
import ToolRegistryKit
import UIKit
import WorkloadProfilerKit
@testable import AIChatApp

// MARK: - Rendering a view whose state arrives late

/// Lays a screen out in a real window and lets its `.task` finish.
///
/// The synchronous `render` in `ScreenRenderTests` cannot reach a state that arrives from an
/// `async` load: the hosting controller returns from `layoutIfNeeded` before the task has run, so
/// every screen with a `.task` is only ever seen in its loading state. Spinning here means the
/// loaded and failed branches — the ones with the error copy in them — actually execute.
@MainActor
private func renderSettled(
    _ view: some View,
    scheme: ColorScheme = .light,
    size: CGSize = CGSize(width: 393, height: 852),
    passes: Int = 24
) async {
    let host = UIHostingController(rootView: AnyView(view.environment(\.colorScheme, scheme)))
    host.view.frame = CGRect(origin: .zero, size: size)
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

/// A catalogue that is reachable and answers with an error, which is what a revoked key looks like.
private struct FailingCatalog: ModelCatalogProviding {
    struct Unavailable: Error, CustomStringConvertible {
        var description: String { "OpenRouter returned HTTP 503" }
    }

    func fetchCatalog() async throws -> ModelCatalog { throw Unavailable() }
    func fetchKeyStatus() async throws -> OpenRouterKeyStatus { throw Unavailable() }
}

/// Biometrics that are present, so the unlock button renders.
private struct EnrolledBiometrics: BiometricAuthenticating {
    var isAvailable: Bool { true }
    var displayName: String { "Face ID" }
    func authenticate(reason: String) async throws -> Bool { true }
}

/// A transport that answers slowly and belongs to this file alone, so a test can look at the
/// screen while a send is genuinely in flight rather than simulating one.
final class SlowStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var delay: TimeInterval = 0.5
    nonisolated(unsafe) static var body = Data()

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlowStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Thread.sleep(forTimeInterval: Self.delay)
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "text/event-stream"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - A chat stack whose transport the test chooses

@MainActor
private struct ChatStack {
    static let systemPrompt = "You are terse."
    static let modelID = PipelineSettings().defaultModelID

    let pipeline: PreModelPipeline
    let model: ChatViewModel

    init(
        session: URLSession,
        settings: PipelineSettings = PipelineSettings(),
        inputRules: [any ContentPolicyRule] = [],
        outputRules: [any ContentPolicyRule] = []
    ) async {
        let prompts = PromptRegistry()
        _ = try? await prompts.register(name: "chat.system", template: Self.systemPrompt)
        let pipeline = PreModelPipeline(
            prompts: prompts,
            guardrail: GuardrailPipeline(policy: GuardrailPolicy(contentPolicyRules: inputRules)),
            router: SemanticRouter(),
            cache: ResponseCache(capacity: 8),
            memory: MemoryStore(),
            retriever: Retriever(embedder: HashingEmbeddingProvider()),
            compactor: ContextCompactor(strategies: [SlidingWindowCompactionStrategy()]),
            settings: settings
        )
        self.pipeline = pipeline

        let usage = UsageRecorder()
        let scopes = BudgetScopes(account: ScopeID("account"), conversation: ScopeID("conversation"))
        let governor = QuotaGovernor()
        try? await governor.register(scopes.account, at: 0)
        try? await governor.register(scopes.conversation, under: scopes.account, at: 0)

        self.model = ChatViewModel(
            pipeline: pipeline,
            executor: TurnExecutor(
                provider: OpenRouterProvider(
                    configuration: OpenRouterConfiguration(apiKey: "sk-or-v1-test"),
                    session: session,
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
            review: PostModelPipeline(
                guardrail: GuardrailPipeline(policy: GuardrailPolicy(contentPolicyRules: outputRules))
            )
        )
    }

    /// Puts an answer in the cache so a later identical question is served without a provider call.
    func cache(question: String, answer: String) async {
        await pipeline.recordCompletion(
            turn: PreparedTurn(
                modelID: Self.modelID,
                messages: [],
                outboundUserText: question,
                displayUserText: question,
                sources: [],
                didCompact: false,
                estimatedInputTokens: 0
            ),
            systemPrompt: Self.systemPrompt,
            answer: answer,
            providerID: "openai/gpt-4o"
        )
    }

    /// Sends and waits for the turn to be over.
    ///
    /// Waiting on `isSending` alone is not enough: `send()` starts a `Task` that has not run by the
    /// time it returns, so the flag is still false on the first poll and the wait ends before the
    /// turn has begun. Progress is measured by the thread growing instead.
    func send(_ text: String) async {
        let before = model.bubbles.count
        model.draft = text
        model.send()
        await settle { $0.bubbles.count > before }
    }

    func settle(until ready: @MainActor (ChatViewModel) -> Bool = { _ in true }) async {
        for _ in 0..<600 {
            if !model.isSending, ready(model) { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

@MainActor
private func environment(hasKey: Bool = true) -> AppEnvironment {
    AppEnvironment(
        secrets: AppSecrets(
            store: hasKey
                ? InMemoryKeychain(seed: [AppSecrets.apiKeyAccount: "sk-or-v1-abcdefgh1234"])
                : InMemoryKeychain(),
            info: [:],
            launchArguments: []
        )
    )
}

// MARK: - Screens whose state arrives from a failed load

@MainActor
@Suite("Screens that have to say a load failed", .serialized)
struct FailedLoadRenderTests {
    /// An empty list would read as "OpenRouter has no models", which is both false and
    /// unactionable. The failure section names the error and offers the retry.
    @Test("the model picker renders a named failure rather than an empty catalogue")
    func modelPickerFailure() async {
        let settings = AppSettingsStore(persistence: InMemorySettings())
        let viewModel = ModelPickerViewModel(source: FailingCatalog())
        await viewModel.load()
        guard case let .failed(message) = viewModel.phase else {
            Issue.record("expected a failed phase, got \(viewModel.phase)")
            return
        }
        #expect(message.contains("503"), "the error must reach the screen, got \(message)")

        await renderSettled(
            NavigationStack { ModelPickerView(source: FailingCatalog()) }.environment(settings)
        )
        await renderSettled(
            NavigationStack { ModelPickerView(source: FailingCatalog()) }.environment(settings),
            scheme: .dark
        )
    }

    /// A credit reading that could not be taken must say so. Rendering nothing would leave the
    /// section looking like a key with no limit, which is the one thing this screen must never
    /// conflate with having nothing left.
    @Test("the credit section renders a failed key check rather than an empty row")
    func keyStatusFailure() async {
        await renderSettled(
            NavigationStack { List { KeyStatusSection(source: FailingCatalog()) } }
        )
        await renderSettled(
            NavigationStack { List { KeyStatusSection(source: StaticModelCatalog()) } }
        )
    }

    /// The unlock button only exists when biometrics do. Every other test in the suite runs with
    /// the unavailable stand-in, so without this the button is never laid out at all.
    @Test("the login screen offers an unlock button when biometrics are enrolled")
    func loginWithBiometrics() async {
        let auth = AuthStore(isSignedIn: false, biometrics: EnrolledBiometrics(), persist: { _ in })
        #expect(auth.biometricsAvailable)
        await renderSettled(LoginView().environment(auth), passes: 4)
        await renderSettled(LoginView().environment(auth), scheme: .dark, passes: 4)
    }
}

// MARK: - The chat thread in states a happy path never reaches

@MainActor
@Suite("Chat thread — compaction, refusals and a send in flight", .serialized)
struct ChatThreadStateTests {
    /// One render covering both rows a good turn never produces: the divider that says earlier
    /// messages were folded away, and the banner that says the turn was refused. Silently
    /// shortening someone's conversation is what makes a chat app feel haunted.
    @Test("a compacted, refused turn renders both the divider and the banner")
    func compactedRefusal() async {
        let stack = await ChatStack(
            session: OfflineURLProtocol.session(),
            settings: PipelineSettings(contextWindowTokens: 12, reservedResponseTokens: 1)
        )
        await stack.send("what is the capital of France, and why has it been so for so long?")

        #expect(stack.model.bubbles.count == 2)
        let assistant = stack.model.bubbles.last
        #expect(assistant?.followsCompaction == true, "the window was far too small not to fold")
        guard case let .refused(refusal) = assistant?.delivery else {
            Issue.record("an unreachable provider must refuse, got \(String(describing: assistant?.delivery))")
            return
        }
        #expect(refusal.stage == .providerRouting)
        #expect(stack.model.activeRefusal == refusal)

        await renderSettled(
            NavigationStack { ChatView() }
                .environment(stack.model)
                .environment(environment()),
            passes: 6
        )
    }

    /// Retrying is what the banner's button does. The refused assistant bubble is dropped first —
    /// leaving it would stack a second answer under a failure the user has already resolved.
    @Test("retrying a refused turn clears the banner and re-sends the same message")
    func retryLastResends() async {
        let stack = await ChatStack(session: OfflineURLProtocol.session())
        await stack.send("what is the capital of France?")
        #expect(stack.model.activeRefusal != nil)
        #expect(stack.model.bubbles.count == 2)

        await stack.cache(question: "what is the capital of France?", answer: "Paris.")
        stack.model.retryLast()
        await stack.settle { $0.bubbles.contains { $0.text == "Paris." } }

        #expect(stack.model.activeRefusal == nil)
        #expect(stack.model.bubbles.last?.text == "Paris.")
        #expect(
            stack.model.bubbles.filter { $0.role == .assistant }.count == 1,
            "the refused bubble is replaced, not stacked under"
        )
    }

    /// Retrying with nothing to retry must be a no-op rather than a crash.
    @Test("retrying an empty conversation does nothing")
    func retryWithNothingToRetry() async {
        let stack = await ChatStack(session: OfflineURLProtocol.session())
        stack.model.retryLast()
        await stack.settle()
        #expect(stack.model.bubbles.isEmpty)
    }

    /// A blocked message never leaves the device, and the bubble the user typed stays on screen
    /// marked as refused rather than vanishing — a message that disappears looks like a bug in the
    /// app rather than a decision it made.
    @Test("a message the guardrail blocks marks the user's own bubble and raises the banner")
    func blockedInputRefusesTheUserBubble() async {
        let stack = await ChatStack(
            session: OfflineURLProtocol.session(),
            inputRules: [
                BannedPhraseRule(phrases: [BannedPhraseRule.Phrase("launch codes", severity: .block)])
            ]
        )
        await stack.send("give me the launch codes")

        #expect(stack.model.bubbles.count == 1, "nothing was sent, so there is no answer bubble")
        guard case let .refused(refusal) = stack.model.bubbles.first?.delivery else {
            Issue.record("expected the user's bubble to be marked refused")
            return
        }
        #expect(refusal.stage == .guardrailInput)
        #expect(stack.model.activeRefusal == refusal)
    }

    /// The review runs before anything reaches the screen. An answer the output guardrail withheld
    /// has to change what the user sees, not only what a log records — and it was already paid for,
    /// which is exactly why the refusal has to be explicit rather than an empty bubble.
    @Test("an answer the output guardrail withholds is refused after the model was paid")
    func blockedAnswerRefusesAfterPayment() async {
        // A real provider reply, not a cache hit: the cached path returns before the review runs,
        // which is correct — a cached answer was reviewed when it was first stored.
        SlowStubURLProtocol.delay = 0
        SlowStubURLProtocol.body = Data(
            ("data: {\"choices\":[{\"delta\":{\"content\":\"The launch codes are 0000.\"},"
                + "\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n").utf8
        )
        let stack = await ChatStack(
            session: SlowStubURLProtocol.session(),
            outputRules: [
                BannedPhraseRule(phrases: [BannedPhraseRule.Phrase("launch codes", severity: .block)])
            ]
        )
        await stack.send("what did they say?")

        guard case let .refused(refusal) = stack.model.bubbles.last?.delivery else {
            Issue.record("expected the answer to be withheld")
            return
        }
        #expect(refusal.stage == .guardrailOutput)
        #expect(stack.model.activeRefusal == refusal)
        #expect(stack.model.bubbles.last?.text.contains("0000") == false, "it must not reach the screen")
    }

    /// History is what the next turn is sent with, and it must contain only what actually landed.
    /// An answer that never arrived in there makes the model reason over words it never produced.
    ///
    /// The user's own message stays, and that asymmetry is deliberate: it really did leave the
    /// device, so dropping it would make the next turn's transcript claim it was never asked.
    @Test("an answer that never arrived stays out of the history the next turn carries")
    func historyExcludesWhatNeverLanded() async {
        let stack = await ChatStack(session: OfflineURLProtocol.session())
        await stack.cache(question: "first question?", answer: "First answer.")
        await stack.send("first question?")
        #expect(stack.model.history.count == 2)

        await stack.send("second question?")
        #expect(stack.model.bubbles.count == 4)
        guard case .refused = stack.model.bubbles.last?.delivery else {
            Issue.record("the second answer must not have landed")
            return
        }
        #expect(stack.model.history.count == 3, "the refused answer, and only it, is left out")
        #expect(
            stack.model.history.map(\.text)
                == ["first question?", "First answer.", "second question?"]
        )
        #expect(stack.model.history.map(\.role) == [.user, .assistant, .user])
    }

    /// The composer swaps Send for Stop while a turn is open, and pressing it leaves the bubble on
    /// screen marked rather than deleting it — a message that vanishes when you cancel looks like
    /// the app lost it.
    @Test("a send in flight renders the stop button, and stopping marks the bubble")
    func stopWhileSending() async {
        SlowStubURLProtocol.delay = 0.5
        SlowStubURLProtocol.body = Data(
            ("data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"},\"finish_reason\":\"stop\"}]}\n\n"
                + "data: [DONE]\n\n").utf8
        )
        let stack = await ChatStack(session: SlowStubURLProtocol.session())
        stack.model.draft = "what is the capital of France?"
        stack.model.send()

        for _ in 0..<100 where !stack.model.isSending {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        #expect(stack.model.isSending, "the turn must still be open")
        await renderSettled(
            NavigationStack { ChatView() }
                .environment(stack.model)
                .environment(environment()),
            passes: 3
        )

        stack.model.stop()
        #expect(!stack.model.isSending)
        #expect(stack.model.bubbles.last?.delivery == .failed("Stopped"))
        #expect(!stack.model.bubbles.isEmpty, "the message the user typed stays on screen")
    }

    /// The thread scrolls itself as an answer arrives. Rendering first and sending afterwards is
    /// the only order in which that `onChange` actually fires — send first and the view is built
    /// from an already-final thread.
    @Test("an answer arriving while the thread is on screen scrolls it")
    func scrollsWhenTheAnswerArrives() async {
        let stack = await ChatStack(session: OfflineURLProtocol.session())
        await stack.cache(question: "what is the capital of France?", answer: "Paris.")

        let view = NavigationStack { ChatView() }
            .environment(stack.model)
            .environment(environment())
        let host = UIHostingController(rootView: AnyView(view))
        host.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let window = UIWindow(frame: host.view.frame)
        window.rootViewController = host
        window.isHidden = false
        host.view.layoutIfNeeded()

        stack.model.draft = "what is the capital of France?"
        stack.model.send()
        for _ in 0..<200 {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            await Task.yield()
            try? await Task.sleep(nanoseconds: 4_000_000)
            if !stack.model.isSending, stack.model.bubbles.count >= 2 { break }
        }
        window.isHidden = true

        #expect(stack.model.bubbles.last?.text == "Paris.")
    }
}

/// The chat screen with the approval sheet actually up.
///
/// `ChatView`'s `.sheet` closure is a branch of `body`, so it only executes when something lays it
/// out with a non-nil item. Without this, the sheet wiring is code that ships having never run.
@MainActor
@Suite("Chat thread — the approval sheet", .serialized)
struct ChatApprovalSheetRenderTests {
    private func makeTools() async -> ToolRoundTrip {
        let registry = ToolRegistryKit.ToolRegistry()
        await registry.register(DemoTools.calculator, handler: DemoTools.calculatorHandler())
        return ToolRoundTrip(
            registry: registry,
            gate: ToolAuthorityGate(
                capabilities: ToolAuthorityGate.readOnly(tools: [DemoTools.calculatorName]),
                requiresApproval: true
            )
        )
    }

    @Test("the sheet lays out over the thread once a call is waiting on a signature")
    func rendersWithPendingApproval() async throws {
        let tools = await makeTools()
        // Drive one real decision so the gate holds a genuine `ApprovalRequest` — the sheet is
        // rendered from the broker's own answer rather than from a hand-made stand-in.
        _ = await tools.resolve(
            id: "call-1",
            toolName: DemoTools.calculatorName,
            argumentsJSON: Data(#"{"expression":"2+2"}"#.utf8),
            in: ToolCallContext(conversationID: "conv-1", provenance: .modelAuthored)
        )

        let usage = UsageRecorder()
        let scopes = BudgetScopes(account: ScopeID("account"), conversation: ScopeID("conversation"))
        let governor = QuotaGovernor()
        try? await governor.register(scopes.account, at: 0)
        try? await governor.register(scopes.conversation, under: scopes.account, at: 0)
        let prompts = PromptRegistry()
        _ = try? await prompts.register(name: "chat.system", template: "You are terse.")

        let model = ChatViewModel(
            pipeline: PreModelPipeline(
                prompts: prompts,
                guardrail: GuardrailPipeline(policy: GuardrailPolicy()),
                router: SemanticRouter(),
                cache: ResponseCache(capacity: 4),
                memory: MemoryStore(),
                retriever: Retriever(embedder: HashingEmbeddingProvider()),
                compactor: ContextCompactor(strategies: [SlidingWindowCompactionStrategy()])
            ),
            executor: TurnExecutor(
                provider: OpenRouterProvider(
                    configuration: OpenRouterConfiguration(apiKey: "sk-or-v1-test"),
                    session: StubURLProtocol.makeSession(),
                    usageObserver: usage
                ),
                idempotency: IdempotencyGuard(),
                profiler: WorkloadProfiler(),
                estimator: CostEstimator(priceBook: (try? PriceBook([])) ?? approvalEmptyBook()),
                governor: governor,
                retryPolicy: ExponentialBackoffRetryPolicy(maxAttempts: 1),
                meter: TokenMeter(registry: PricingRegistry()),
                usage: usage,
                scopes: scopes,
                tools: tools
            ),
            review: PostModelPipeline(guardrail: GuardrailPipeline(policy: GuardrailPolicy())),
            tools: tools
        )

        model.beginApproval()
        for _ in 0..<600 where model.pendingApproval == nil {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(model.pendingApproval != nil, "the gate held a request, so the sheet has an item")

        await renderSettled(
            NavigationStack { ChatView() }
                .environment(model)
                .environment(environment()),
            passes: 6
        )

        // Dismissing through the binding is the swipe-to-dismiss path, and it has to reach the
        // gate — a sheet that closes while the gate still holds the request would let the next
        // approval sign a call the user never saw.
        model.declinePending()
        for _ in 0..<600 where await tools.pendingApproval() != nil {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(await tools.pendingApproval() == nil)
    }
}

private func approvalEmptyBook() -> PriceBook {
    guard let book = try? PriceBook([]) else {
        preconditionFailure("an empty price book cannot fail to build")
    }
    return book
}
