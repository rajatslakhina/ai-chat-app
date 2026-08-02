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
import SnapshotTesting
import SwiftUI
import Testing
import TokenMeterKit
import UIKit
import WorkloadProfilerKit
@testable import AIChatApp

// MARK: - How a render is pinned

/// Everything that decides what a reference image contains, in one place.
///
/// A snapshot is only worth having if the same view produces the same bytes tomorrow. Three things
/// are pinned deliberately:
///
/// 1. **The device.** `iPhone13Pro`, not whatever simulator the suite happens to be booted on. The
///    gate runs on an iPhone 17 Pro; a reference recorded at that size would be a fact about this
///    machine rather than about the view.
/// 2. **The traits.** Colour scheme and content size category are set explicitly rather than
///    inherited, because inheriting them means the images change when someone's simulator has a
///    different appearance setting.
/// 3. **The record mode.** `.never`, not the library default of `.missing`. A suite that quietly
///    re-records a reference it cannot find asserts nothing on exactly the machine you wanted it
///    to fail on. The images are committed; a missing one is a defect, not a cue to write it.
private enum Snap {
    static let device = ViewImageConfig.iPhone13Pro

    /// Set to `.all` for one run to re-record, then put back. Never leave it on `.all`.
    static let record: SnapshotTestingConfiguration.Record = .never

    /// Not 1.0. A rendered image is produced by the GPU, and antialiasing along a rounded corner
    /// differs by a hair between OS point releases. An exact comparison turns that into a red
    /// suite that says nothing about the view; 99% of pixels within 98% perceptual distance still
    /// fails on a moved control, a wrong colour or a missing row, which is what these assert.
    static let precision: Float = 0.99
    static let perceptualPrecision: Float = 0.98

    static func traits(
        _ style: UIUserInterfaceStyle,
        size: UIContentSizeCategory = .large
    ) -> UITraitCollection {
        device.traits.modifyingTraits { traits in
            traits.userInterfaceStyle = style
            traits.preferredContentSizeCategory = size
        }
    }

    static func config(
        _ style: UIUserInterfaceStyle,
        size: UIContentSizeCategory = .large
    ) -> ViewImageConfig {
        var config = device
        config.traits = traits(style, size: size)
        return config
    }
}

/// A whole screen, laid out at device size with safe areas.
@MainActor
private func assertScreen(
    _ view: some View,
    _ style: UIUserInterfaceStyle,
    size: UIContentSizeCategory = .large,
    named name: String,
    fileID: StaticString = #fileID,
    file filePath: StaticString = #filePath,
    testName: String = #function,
    line: UInt = #line,
    column: UInt = #column
) {
    let config = Snap.config(style, size: size)
    assertSnapshot(
        of: view,
        as: .image(
            precision: Snap.precision,
            perceptualPrecision: Snap.perceptualPrecision,
            layout: .device(config: config),
            traits: config.traits
        ),
        named: name,
        record: Snap.record,
        fileID: fileID,
        file: filePath,
        testName: testName,
        line: line,
        column: column
    )
}

/// One component, sized to its own content on a plain background.
///
/// `.sizeThatFits` rather than a device frame: a bubble that grew a row is the thing being
/// asserted, and 700 rows of empty canvas underneath it would dilute a pixel comparison to the
/// point where the growth no longer registers.
@MainActor
private func assertComponent(
    _ view: some View,
    _ style: UIUserInterfaceStyle,
    size: UIContentSizeCategory = .large,
    width: CGFloat = 360,
    named name: String,
    fileID: StaticString = #fileID,
    file filePath: StaticString = #filePath,
    testName: String = #function,
    line: UInt = #line,
    column: UInt = #column
) {
    let framed = view
        .frame(width: width)
        .padding(Theme.Spacing.regular)
        .background(Theme.Palette.canvas)
    assertSnapshot(
        of: framed,
        as: .image(
            precision: Snap.precision,
            perceptualPrecision: Snap.perceptualPrecision,
            layout: .sizeThatFits,
            traits: Snap.traits(style, size: size)
        ),
        named: name,
        record: Snap.record,
        fileID: fileID,
        file: filePath,
        testName: testName,
        line: line,
        column: column
    )
}

// MARK: - Fixtures

/// The bubble states the thread can be in, built by hand rather than driven through the pipeline.
///
/// Driving them would mean a network stub per variant and a settled turn per variant, and the
/// thing under test here is the row, not the send. Every field set below is one a real turn writes.
enum BubbleFixture {
    /// A fixed instant. The details sheet renders a timestamp, so a `Date()` default would put
    /// today's date into a reference image and the suite would go red every midnight — exactly the
    /// non-determinism the device and traits are pinned to avoid.
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    static let refusal = Refusal(
        stage: .budgetReserve,
        headline: "Out of budget",
        explanation: "account has 0 microcents left and this message needs 4,200.",
        recovery: .addCredit
    )

    static let metrics = TurnCompletion(
        text: "Paris is the capital of France.",
        providerID: "openai/gpt-4o",
        promptTokens: 318,
        completionTokens: 74,
        reportedCostUSD: 0.000104,
        meteredCostUSD: Decimal(string: "0.000104") ?? 0,
        attempts: 2
    )

    static let sources = [
        RetrievedSource(
            id: "chunk-1",
            title: "france.md",
            snippet: "Paris has been the capital since 987.",
            relevancePercent: 91
        ),
        RetrievedSource(
            id: "chunk-2",
            title: "europe.md",
            snippet: "The Île-de-France region surrounds the city.",
            relevancePercent: 64
        )
    ]

    static func user(_ text: String) -> ChatBubble {
        ChatBubble(role: .user, text: text)
    }

    static var delivered: ChatBubble {
        ChatBubble(role: .assistant, text: "Paris is the capital of **France**.")
    }

    static var streaming: ChatBubble {
        ChatBubble(role: .assistant, text: "Paris is the ca", delivery: .streaming)
    }

    /// Empty text plus `.sending` is the state that renders the typing indicator.
    static var pending: ChatBubble {
        ChatBubble(role: .assistant, text: "", delivery: .sending)
    }

    static var refused: ChatBubble {
        ChatBubble(role: .assistant, text: "", delivery: .refused(refusal))
    }

    static var failed: ChatBubble {
        ChatBubble(
            role: .assistant,
            text: "",
            delivery: .failed("the connection dropped after 1.2s")
        )
    }

    static var withMetrics: ChatBubble {
        ChatBubble(
            role: .assistant,
            text: "Paris is the capital of France.",
            metrics: metrics,
            createdAt: epoch
        )
    }

    static var withSources: ChatBubble {
        ChatBubble(
            role: .assistant,
            text: "Paris is the capital of France.",
            metrics: metrics,
            sources: sources,
            followsCompaction: true,
            groundedFraction: 0.75,
            claimCount: 4,
            createdAt: epoch
        )
    }

    static var toolRunning: ChatBubble {
        var bubble = ChatBubble(role: .assistant, text: "Let me work that out.")
        bubble.toolState = .running("calculator")
        return bubble
    }

    static var toolUsed: ChatBubble {
        var bubble = ChatBubble(role: .assistant, text: "That comes to 84.", metrics: metrics)
        bubble.toolState = .used(["calculator", "current_time"])
        return bubble
    }

    static var toolFailed: ChatBubble {
        var bubble = ChatBubble(role: .assistant, text: "I couldn't compute that.")
        bubble.toolState = .failed(tool: "calculator", message: "division by zero")
        return bubble
    }
}

/// A whole chat stack whose only answer comes from the response cache.
///
/// Deliberately no `URLProtocol` stub. Stubbed transport is process-global state, and a snapshot
/// suite that shares it with the other suites would produce reference images that depend on test
/// ordering. Seeding the cache means `PreModelPipeline` short-circuits before the provider is ever
/// reached, so this harness makes no network call of any kind and always renders the same thread.
@MainActor
private struct ChatSnapshotHarness {
    static let systemPrompt = "You are terse."
    static let modelID = PipelineSettings().defaultModelID
    static let question = "What is the capital of France?"
    static let answer = "Paris is the capital of **France** — and has been since 987."

    let pipeline: PreModelPipeline
    let model: ChatViewModel

    init() async {
        let prompts = PromptRegistry()
        _ = try? await prompts.register(name: "chat.system", template: Self.systemPrompt)
        let pipeline = PreModelPipeline(
            prompts: prompts,
            guardrail: GuardrailPipeline(policy: GuardrailPolicy()),
            router: SemanticRouter(),
            cache: ResponseCache(capacity: 4),
            memory: MemoryStore(),
            retriever: Retriever(embedder: HashingEmbeddingProvider()),
            compactor: ContextCompactor(strategies: [SlidingWindowCompactionStrategy()])
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
                    configuration: OpenRouterConfiguration(apiKey: "sk-or-v1-snapshot"),
                    session: .shared,
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

    /// Seeds the cache with the answer this conversation will "receive", then sends the question.
    func seedAndSend() async {
        await pipeline.recordCompletion(
            turn: PreparedTurn(
                modelID: Self.modelID,
                messages: [],
                outboundUserText: Self.question,
                displayUserText: Self.question,
                sources: [],
                didCompact: false,
                estimatedInputTokens: 0
            ),
            systemPrompt: Self.systemPrompt,
            answer: Self.answer,
            providerID: "openai/gpt-4o"
        )
        model.draft = Self.question
        model.send()
        for _ in 0..<600 where model.isSending || model.bubbles.count < 2 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

/// `PriceBook([])` throws only on a duplicate model and there are no entries. Named once here so
/// the snapshot suite is not a third place carrying the same fallback.
enum TestPriceBook {
    static let empty: PriceBook = {
        guard let book = try? PriceBook([]) else {
            preconditionFailure("an empty price book cannot fail to build")
        }
        return book
    }()
}

@MainActor
private func environment(hasKey: Bool) -> AppEnvironment {
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

/// A trace with one of every outcome kind in it, so the Diagnostics reference image is the one
/// that actually distinguishes the five colours.
private func mixedTrace() -> PipelineTrace {
    var trace = PipelineTrace()
    trace.record(.promptTemplate, .ran(detail: "chat.system v1"), durationMs: 2)
    trace.record(.guardrailInput, .noOp(reason: "no findings"), durationMs: 1)
    trace.record(.cacheLookup, .skipped(reason: "cache disabled in Settings"))
    trace.record(.budgetReserve, .refused(BubbleFixture.refusal), durationMs: 4)
    trace.record(.metering, .failed(message: "the provider reported no usage"), durationMs: 1)
    trace.record(.providerRouting, .ran(detail: "answered by openai/gpt-4o"), durationMs: 812)
    return trace
}

// MARK: - Components

@MainActor
@Suite("Snapshots — components")
struct ComponentSnapshotTests {
    @Test("a delivered bubble, light and dark")
    func delivered() {
        assertComponent(BubbleRow(bubble: BubbleFixture.delivered), .light, named: "light")
        assertComponent(BubbleRow(bubble: BubbleFixture.delivered), .dark, named: "dark")
    }

    @Test("a user bubble sits on the other side, in both schemes")
    func userBubble() {
        let bubble = BubbleFixture.user("What is the capital of France?")
        assertComponent(BubbleRow(bubble: bubble), .light, named: "light")
        assertComponent(BubbleRow(bubble: bubble), .dark, named: "dark")
    }

    @Test("a streaming bubble, and the typing indicator that precedes it")
    func streaming() {
        assertComponent(BubbleRow(bubble: BubbleFixture.streaming), .light, named: "partial")
        assertComponent(BubbleRow(bubble: BubbleFixture.pending), .light, named: "typing")
        assertComponent(BubbleRow(bubble: BubbleFixture.pending), .dark, named: "typing-dark")
    }

    /// A refusal and a failure must never look alike. Two references, one comparison, and a
    /// regression that collapsed them into one colour changes both images.
    @Test("a refused bubble and a failed bubble, in both schemes")
    func refusedAndFailed() {
        assertComponent(BubbleRow(bubble: BubbleFixture.refused), .light, named: "refused-light")
        assertComponent(BubbleRow(bubble: BubbleFixture.refused), .dark, named: "refused-dark")
        assertComponent(BubbleRow(bubble: BubbleFixture.failed), .light, named: "failed-light")
        assertComponent(BubbleRow(bubble: BubbleFixture.failed), .dark, named: "failed-dark")
    }

    /// Aimed at the details sheet, not at the bubble.
    ///
    /// These facts used to sit under the bubble as chips and now live behind "More", so pointing
    /// the reference at `BubbleRow` would have recorded an empty bubble and quietly stopped
    /// asserting the thing the test is named for.
    @Test("the details sheet carries model, tokens, cost and a retry count")
    func withMetrics() {
        // `assertScreen`, not `assertComponent`: a `NavigationStack` wrapping a `List` has no
        // intrinsic height, so `.sizeThatFits` collapses it to a blank strip.
        assertScreen(MessageDetailsSheet(bubble: BubbleFixture.withMetrics), .light, named: "light")
        assertScreen(MessageDetailsSheet(bubble: BubbleFixture.withMetrics), .dark, named: "dark")
    }

    @Test("the details sheet lists sources and the grounding score")
    func withSources() {
        assertScreen(MessageDetailsSheet(bubble: BubbleFixture.withSources), .light, named: "light")
        assertScreen(MessageDetailsSheet(bubble: BubbleFixture.withSources), .dark, named: "dark")
    }

    /// The row itself, which is what replaced the chips under a bubble.
    @Test("the action row, with and without the controls only a user message gets")
    func actionRow() {
        let mine = BubbleActions(canRevise: true)
        let theirs = BubbleActions(canRevise: false)
        assertComponent(MessageActionsRow(actions: mine), .light, named: "user")
        assertComponent(MessageActionsRow(actions: theirs), .light, named: "assistant")
        assertComponent(
            MessageActionsRow(actions: BubbleActions(isSpeaking: true, canRevise: true)),
            .light,
            named: "speaking"
        )
    }

    @Test("every tool chip state")
    func toolChips() {
        assertComponent(BubbleRow(bubble: BubbleFixture.toolRunning), .light, named: "running")
        assertComponent(BubbleRow(bubble: BubbleFixture.toolUsed), .light, named: "used")
        assertComponent(BubbleRow(bubble: BubbleFixture.toolFailed), .light, named: "failed")
        assertComponent(BubbleRow(bubble: BubbleFixture.toolFailed), .dark, named: "failed-dark")
    }

    @Test("the refusal banner, with a recovery action and without one")
    func refusalBanner() {
        let recoverable = RefusalBanner(refusal: BubbleFixture.refusal) {}
        assertComponent(recoverable, .light, named: "light")
        assertComponent(recoverable, .dark, named: "dark")
        assertComponent(
            recoverable,
            .light,
            size: .accessibilityExtraExtraExtraLarge,
            named: "xxxl"
        )
        // A refusal with nowhere to go is still shown; it just does not draw a button that
        // cannot work. That absence is the thing this reference pins.
        let deadEnd = Refusal(
            stage: .guardrailInput,
            headline: "Message not sent",
            explanation: "The guardrail withheld this message.",
            recovery: nil
        )
        assertComponent(RefusalBanner(refusal: deadEnd, onRecover: nil), .light, named: "no-action")
    }

    @Test("the compaction divider")
    func compactionDivider() {
        assertComponent(CompactionDivider(), .light, named: "light")
        assertComponent(CompactionDivider(), .dark, named: "dark")
    }

    @Test("metric chips: bare, with an icon, and tinted")
    func metricChips() {
        let row = VStack(alignment: .leading, spacing: Theme.Spacing.snug) {
            MetricChip("318 in / 74 out")
            MetricChip("openai/gpt-4o", icon: "cpu")
            MetricChip("$0.000104", icon: "creditcard", tint: Theme.Palette.success)
            MetricChip("Retried 2×", icon: "arrow.clockwise", tint: Theme.Palette.refusal)
            MetricChip("stream dropped", icon: "exclamationmark.triangle", tint: Theme.Palette.failure)
        }
        assertComponent(row, .light, named: "light")
        assertComponent(row, .dark, named: "dark")
        assertComponent(row, .light, size: .accessibilityExtraExtraExtraLarge, named: "xxxl")
    }
}

// MARK: - Screens

@MainActor
@Suite("Snapshots — screens")
struct ScreenSnapshotTests {
    @Test("the login screen")
    func login() {
        let view = LoginView()
            .environment(AuthStore(isSignedIn: false, biometrics: UnavailableBiometrics()))
        assertScreen(view, .light, named: "light")
        assertScreen(view, .dark, named: "dark")
        assertScreen(view, .light, size: .accessibilityExtraExtraExtraLarge, named: "xxxl")
    }

    /// The failure line only renders once a sign-in has been rejected, so it needs a store that
    /// has already been asked and refused rather than a fresh one.
    @Test("the login screen showing a rejected credential")
    func loginRejected() {
        let auth = AuthStore(isSignedIn: false, biometrics: UnavailableBiometrics())
        auth.signIn(email: "someone@example.com", passphrase: "nope")
        #expect(auth.failure == .wrongCredentials)
        assertScreen(LoginView().environment(auth), .light, named: "light")
    }

    @Test("the empty chat, with a key and without one")
    func emptyChat() async {
        let harness = await ChatSnapshotHarness()
        #expect(harness.model.bubbles.isEmpty)
        for (hasKey, name) in [(true, "with-key"), (false, "no-key")] {
            let view = NavigationStack { ChatView() }
                .environment(harness.model)
                .environment(environment(hasKey: hasKey))
            assertScreen(view, .light, named: name)
        }
        let dark = NavigationStack { ChatView() }
            .environment(harness.model)
            .environment(environment(hasKey: true))
        assertScreen(dark, .dark, named: "dark")
    }

    @Test("a chat with a delivered turn and follow-up chips")
    func populatedChat() async {
        let harness = await ChatSnapshotHarness()
        await harness.seedAndSend()
        #expect(harness.model.bubbles.count == 2, "the cache must answer without a provider call")
        #expect(harness.model.bubbles.last?.text == ChatSnapshotHarness.answer)

        harness.model.applyMetadata(
            ChatMetadata(
                title: "Capital of France",
                followUps: ["What is the population?", "When was it founded?"],
                titleSource: .model
            ),
            trace: PipelineTrace(),
            from: 1
        )
        #expect(harness.model.followUps.count == 2, "one send advances the generation exactly once")

        let view = NavigationStack { ChatView() }
            .environment(harness.model)
            .environment(environment(hasKey: true))
        assertScreen(view, .light, named: "light")
        assertScreen(view, .dark, named: "dark")
        assertScreen(view, .light, size: .accessibilityExtraExtraExtraLarge, named: "xxxl")
    }

    @Test("the model picker")
    func modelPicker() {
        let settings = AppSettingsStore(persistence: InMemorySettings())
        let view = NavigationStack { ModelPickerView(source: StaticModelCatalog()) }
            .environment(settings)
        assertScreen(view, .light, named: "light")
        assertScreen(view, .dark, named: "dark")
        assertScreen(view, .light, size: .accessibilityExtraExtraExtraLarge, named: "xxxl")
    }

    @Test("settings, against a key that is set and one that is not")
    func settings() {
        let settings = AppSettingsStore(persistence: InMemorySettings())
        settings.budgetCeilingUSD = 5
        let view = NavigationStack { SettingsView(catalog: StaticModelCatalog()) }
            .environment(environment(hasKey: true))
            .environment(settings)
        assertScreen(view, .light, named: "light")
        assertScreen(view, .dark, named: "dark")
        assertScreen(view, .light, size: .accessibilityExtraExtraExtraLarge, named: "xxxl")

        let unlimited = AppSettingsStore(persistence: InMemorySettings())
        let absent = NavigationStack { SettingsView(catalog: StaticModelCatalog()) }
            .environment(environment(hasKey: false))
            .environment(unlimited)
        assertScreen(absent, .light, named: "no-key")
    }

    @Test("diagnostics, empty and with one of every outcome")
    func diagnostics() async {
        let harness = await ChatSnapshotHarness()
        let empty = NavigationStack { DiagnosticsView() }.environment(harness.model)
        assertScreen(empty, .light, named: "empty")

        harness.model.applyMetadata(nil, trace: mixedTrace(), from: 0)
        #expect(harness.model.trace.records.count == 6)
        let populated = NavigationStack { DiagnosticsView() }.environment(harness.model)
        assertScreen(populated, .light, named: "light")
        assertScreen(populated, .dark, named: "dark")
        assertScreen(populated, .light, size: .accessibilityExtraExtraExtraLarge, named: "xxxl")
    }
}
