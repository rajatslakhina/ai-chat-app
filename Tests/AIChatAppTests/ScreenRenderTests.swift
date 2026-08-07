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
        // Built and discarded on purpose: `ChatScaffold` composes its own view model, so this only
        // proves the shared fixture still constructs under the environment below. Binding it to a
        // name is a warning in a clean build; deleting the call would stop proving that.
        _ = await makeChatModel()
        let settings = AppSettingsStore(persistence: InMemorySettings())
        let environment = AppEnvironment(
            secrets: AppSecrets(store: InMemoryKeychain(), info: [:], launchArguments: [])
        )
        // The shell now roots at the chat list, so it needs whose chats those are. In-memory
        // stores for the same reason the settings are: a render test that read the simulator's
        // real profiles would pass here and fail on a machine that had used the app.
        let profiles = ProfileStore(persistence: InMemoryProfiles())
        let conversations = ConversationStore(
            profileID: profiles.activeID,
            persistence: InMemoryConversations()
        )
        conversations.startConversation(modelID: "openai/gpt-4o")
        render(
            ChatScaffold(
                composition: await Composition.build(
                    apiKey: "",
                    secrets: environment.secrets,
                    arguments: ["-UITestMode"]
                )
            )
            .environment(AuthStore(isSignedIn: true, biometrics: UnavailableBiometrics()))
            .environment(environment)
            .environment(settings)
            .environment(profiles)
            .environment(conversations)
        )
    }
}

/// The approval sheet, in both provenance states and both colour schemes.
///
/// Rendered rather than only unit-tested because the untrusted banner is a branch in `body`, and a
/// branch in `body` that nothing lays out has never run — which is exactly how a force-unwrap or a
/// bad `Label` composition ships in the one screen whose entire job is to be read carefully.
@MainActor
@Suite("Tool approval sheet renders")
struct ToolApprovalSheetRenderTests {
    private func prompt(untrusted: Bool) -> ToolApprovalPrompt {
        ToolApprovalPrompt(
            request: ApprovalRequest(
                proposal: ToolProposal(
                    id: "p-1",
                    principal: "conv-1",
                    tool: ToolName("calculator"),
                    action: .read,
                    resource: ResourcePath("tools/calculator"),
                    arguments: #"{"expression":"2+2"}"#,
                    provenance: untrusted ? .untrusted(source: "doc-1") : .modelAuthored
                ),
                grantID: "conv-conv-1"
            )
        )
    }

    @Test("a model-authored call renders without the warning")
    func modelAuthored() {
        render(ToolApprovalSheet(prompt: prompt(untrusted: false), onApprove: {}, onDecline: {}))
    }

    @Test("an untrusted call renders the warning that makes it worth refusing")
    func untrusted() {
        render(ToolApprovalSheet(prompt: prompt(untrusted: true), onApprove: {}, onDecline: {}))
        render(
            ToolApprovalSheet(prompt: prompt(untrusted: true), onApprove: {}, onDecline: {}),
            scheme: .dark
        )
    }

    @Test("an argument-less call still shows something rather than an empty box")
    func emptyArguments() {
        let empty = ToolApprovalPrompt(
            request: ApprovalRequest(
                proposal: ToolProposal(
                    id: "p-2",
                    principal: "conv-1",
                    tool: ToolName("current_time"),
                    action: .read,
                    resource: ResourcePath("tools/current_time"),
                    arguments: "",
                    provenance: .modelAuthored
                ),
                grantID: "conv-conv-1"
            )
        )
        #expect(empty.arguments.isEmpty)
        render(ToolApprovalSheet(prompt: empty, onApprove: {}, onDecline: {}))
    }
}

/// The screens added with profiles and history, plus the sheet the bubble's "More" opens.
///
/// These had no render test when they landed, which is how `ProfileView` reached 0% coverage
/// while every other screen sat above 98%: a SwiftUI `body` only runs when something lays it out.
@MainActor
@Suite("Profile and list screens render")
struct ProfileAndListRenderTests {
    private func stores() -> (ProfileStore, ConversationStore) {
        let profiles = ProfileStore(persistence: InMemoryProfiles())
        let conversations = ConversationStore(
            profileID: profiles.activeID,
            persistence: InMemoryConversations()
        )
        return (profiles, conversations)
    }

    @Test("the chat list renders empty and populated, in both schemes")
    func chatList() {
        let (profiles, conversations) = stores()
        render(
            NavigationStack { ChatListView(openConversationID: .constant(nil)) }
                .environment(profiles)
                .environment(conversations)
                .environment(AppSettingsStore(persistence: InMemorySettings()))
        )

        let started = conversations.startConversation(modelID: "openai/gpt-4o")
        conversations.replaceMessages(
            [StoredMessage(role: .user, text: "What is the capital of France?")],
            in: started.id
        )
        for scheme in [ColorScheme.light, .dark] {
            render(
                NavigationStack { ChatListView(openConversationID: .constant(nil)) }
                    .environment(profiles)
                    .environment(conversations)
                    .environment(AppSettingsStore(persistence: InMemorySettings())),
                scheme: scheme
            )
        }
    }

    @Test("the profile screen renders, with one profile and with several")
    func profile() {
        let (profiles, _) = stores()
        let auth = AuthStore(isSignedIn: true, biometrics: UnavailableBiometrics())
        render(NavigationStack { ProfileView() }.environment(profiles).environment(auth))

        // The switch section only appears once there is somewhere to switch to, so both shapes
        // have to be laid out or half the screen never executes.
        profiles.addProfile(displayName: "Sam Rivera", email: "sam@example.test")
        for scheme in [ColorScheme.light, .dark] {
            render(
                NavigationStack { ProfileView() }.environment(profiles).environment(auth),
                scheme: scheme
            )
        }
    }

    @Test("editing a profile renders its form")
    func editProfile() {
        render(EditProfileView(profile: UserProfile(displayName: "Ada Lovelace")) { _ in })
    }

    @Test("the details sheet renders for a bare message and a fully-annotated one")
    func details() {
        render(MessageDetailsSheet(bubble: ChatBubble(role: .user, text: "hello")))
        render(MessageDetailsSheet(bubble: ChatBubble(role: .assistant, text: "hi")), scheme: .dark)
    }
}
