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
import UIKit
import WorkloadProfilerKit
@testable import AIChatApp

/// Lays a screen out for real, in a window, at a given colour scheme.
///
/// A view's `body` is the one part of a SwiftUI screen that only runs when something asks for it,
/// so a screen with no test that renders it has never actually executed — a crash in a branch that
/// only a refused trace reaches would ship. This forces the layout pass rather than asserting on
/// pixels: the claim being made is "these states render", which is exactly what a `precondition`,
/// a force-unwrap or a bad `ForEach` identity would break.
@MainActor
private func render(
    _ view: some View,
    scheme: ColorScheme = .light,
    size: CGSize = CGSize(width: 393, height: 852)
) {
    let host = UIHostingController(rootView: AnyView(view.environment(\.colorScheme, scheme)))
    host.view.frame = CGRect(origin: .zero, size: size)
    let window = UIWindow(frame: host.view.frame)
    window.rootViewController = host
    window.isHidden = false
    host.view.setNeedsLayout()
    host.view.layoutIfNeeded()
    window.isHidden = true
}

@MainActor
private func makeChatModel() async -> ChatViewModel {
    let usage = UsageRecorder()
    let scopes = BudgetScopes(account: ScopeID("account"), conversation: ScopeID("conversation"))
    let governor = QuotaGovernor()
    try? await governor.register(scopes.account, at: 0)
    try? await governor.register(scopes.conversation, under: scopes.account, at: 0)
    let prompts = PromptRegistry()
    _ = try? await prompts.register(name: "chat.system", template: "You are terse.")

    return ChatViewModel(
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
            estimator: CostEstimator(priceBook: (try? PriceBook([])) ?? emptyBook()),
            governor: governor,
            retryPolicy: ExponentialBackoffRetryPolicy(maxAttempts: 1),
            meter: TokenMeter(registry: PricingRegistry()),
            usage: usage,
            scopes: scopes
        ),
        review: PostModelPipeline(guardrail: GuardrailPipeline(policy: GuardrailPolicy()))
    )
}

private func emptyBook() -> PriceBook {
    guard let book = try? PriceBook([]) else {
        preconditionFailure("an empty price book cannot fail to build")
    }
    return book
}

/// A trace carrying one of every outcome, so the rows that colour them are all reached.
private func mixedTrace() -> PipelineTrace {
    var trace = PipelineTrace()
    trace.record(.promptTemplate, .ran(detail: "chat.system v1"), durationMs: 2)
    trace.record(.guardrailInput, .noOp(reason: "no findings"), durationMs: 1)
    trace.record(.cacheLookup, .skipped(reason: "cache disabled in Settings"))
    trace.record(
        .budgetReserve,
        .refused(
            Refusal(
                stage: .budgetReserve,
                headline: "Out of budget",
                explanation: "account has 0 microcents left and this message needs 4200",
                recovery: .addCredit
            )
        ),
        durationMs: 4
    )
    trace.record(.metering, .failed(message: "the provider reported no usage"), durationMs: 1)
    // Twice, because the screen must not collapse a stage that reported more than once.
    trace.record(.providerRouting, .ran(detail: "answered by openai/gpt-4o"), durationMs: 812)
    trace.record(.providerRouting, .failed(message: "stream dropped"), durationMs: 9)
    return trace
}

@MainActor
@Suite("Screen rendering", .serialized)
struct ScreenRenderTests {
    @Test("Diagnostics renders an empty trace as every stage unreached")
    func diagnosticsEmpty() async {
        let model = await makeChatModel()
        #expect(model.trace.unreached.count == PipelineStage.allCases.count)
        render(DiagnosticsView().environment(model))
        render(DiagnosticsView().environment(model), scheme: .dark)
    }

    /// The populated screen is the one with branches in it — five outcome colours, a repeated
    /// stage, and a shrinking unreached list.
    @Test("Diagnostics renders every outcome kind, in both colour schemes")
    func diagnosticsPopulated() async {
        let model = await makeChatModel()
        model.applyMetadata(nil, trace: mixedTrace(), from: 0)

        #expect(model.trace.records.count == 7)
        #expect(model.trace.refusal?.headline == "Out of budget")
        render(DiagnosticsView().environment(model))
        render(DiagnosticsView().environment(model), scheme: .dark)
        render(
            DiagnosticsView().environment(model),
            size: CGSize(width: 320, height: 480)
        )
    }

    /// Every stage reporting is a distinct branch: the unreached section is replaced by a single
    /// "everything reported" row, which no other test reaches.
    @Test("Diagnostics renders a trace in which nothing is unreached")
    func diagnosticsComplete() async {
        let model = await makeChatModel()
        var trace = PipelineTrace()
        for stage in PipelineStage.allCases {
            trace.record(stage, .ran(detail: "did the thing"), durationMs: 1)
        }
        model.applyMetadata(nil, trace: trace, from: 0)

        #expect(model.trace.unreached.isEmpty)
        render(DiagnosticsView().environment(model))
    }

    @Test("the model picker renders its loaded, empty and failed states")
    func modelPicker() {
        let settings = AppSettingsStore(persistence: InMemorySettings())
        render(
            NavigationStack { ModelPickerView(source: StaticModelCatalog()) }
                .environment(settings)
        )
        render(
            NavigationStack { ModelPickerView(source: StaticModelCatalog()) }
                .environment(settings),
            scheme: .dark
        )
        render(
            NavigationStack {
                ModelPickerView(source: StaticModelCatalog(catalog: ModelCatalog(models: [])))
            }
            .environment(settings)
        )
    }

    @Test("Settings renders against a key that is present and one that is absent")
    func settings() {
        let settings = AppSettingsStore(persistence: InMemorySettings())
        let absent = AppEnvironment(
            secrets: AppSecrets(store: InMemoryKeychain(), info: [:], launchArguments: [])
        )
        let present = AppEnvironment(
            secrets: AppSecrets(
                store: InMemoryKeychain(seed: [AppSecrets.apiKeyAccount: "sk-or-v1-abcdefgh1234"]),
                info: [:],
                launchArguments: []
            )
        )
        for environment in [absent, present] {
            render(
                NavigationStack { SettingsView(catalog: StaticModelCatalog()) }
                    .environment(environment)
                    .environment(settings)
            )
        }
        settings.budgetCeilingUSD = 5
        render(
            NavigationStack { SettingsView(catalog: StaticModelCatalog()) }
                .environment(present)
                .environment(settings),
            scheme: .dark
        )
    }

    /// A key status with a real limit that has been used up — the branch that shows the
    /// exhausted warning, which the unlimited fixture never reaches.
    @Test("Settings renders an exhausted key without claiming an unlimited one is exhausted")
    func exhaustedKeyStatus() {
        let exhausted = OpenRouterKeyStatus.Envelope.self
        let json = #"{"data":{"label":"k","usage":5,"limit":5,"limit_remaining":0}}"#
        guard let decoded = try? JSONDecoder().decode(exhausted, from: Data(json.utf8)) else {
            Issue.record("the fixture must decode")
            return
        }
        #expect(decoded.data.isExhausted)
        render(
            NavigationStack {
                List { KeyStatusSection(source: StaticModelCatalog(keyStatus: decoded.data)) }
            }
        )
    }

    @Test("the chat scaffold renders with its toolbar and every destination")
    func scaffoldDestinations() async {
        let model = await makeChatModel()
        let settings = AppSettingsStore(persistence: InMemorySettings())
        let environment = AppEnvironment(
            secrets: AppSecrets(store: InMemoryKeychain(), info: [:], launchArguments: [])
        )
        render(
            ChatScaffold(
                composition: await Composition.build(
                    apiKey: "",
                    secrets: environment.secrets,
                    arguments: ["-UITestMode"]
                ),
                model: model
            )
            .environment(AuthStore(isSignedIn: true, biometrics: UnavailableBiometrics()))
            .environment(environment)
            .environment(settings)
        )
    }
}
