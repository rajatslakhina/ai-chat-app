import CostEstimatorKit
import Foundation
import IdempotencyKit
import LocalAuthentication
import ProviderGatewayKit
import QuotaGovernorKit
import RetrievalKit
import RetryPolicyKit
import SchemaMigrationKit
import Security
import Testing
import TokenMeterKit
import ToolAuthorityKit
import ToolRegistryKit
import WorkloadProfilerKit
@testable import AIChatApp

// MARK: - Keychain failure paths

/// A `Security` layer that answers with whatever `OSStatus` the test wants.
///
/// The real Keychain is exercised separately, in `KeychainStoreTests`; what it cannot do is fail
/// on demand. `SecItemUpdate` returning `errSecInteractionNotAllowed` is not a hypothetical — it is
/// what happens when the device is locked and the item is protected — and the branch that turns it
/// into a thrown `KeychainError` is the entire reason this store is not a `try?` at the call site.
private struct StubSecItems: SecItemPerforming {
    /// What `SecItemCopyMatching` writes back. Held as a value rather than a `CFTypeRef` because
    /// `CFTypeRef` is `AnyObject`, which no `Sendable` struct may carry under strict concurrency.
    enum Stored: Sendable {
        case nothing
        case bytes(Data)
        /// Something that is not `Data` at all, which is one of the two corruption shapes.
        case notData(String)
    }

    var copyStatus: OSStatus = errSecSuccess
    var copyResult: Stored = .nothing
    var updateStatus: OSStatus = errSecSuccess
    var addStatus: OSStatus = errSecSuccess
    var deleteStatus: OSStatus = errSecSuccess

    func copyMatching(
        _ query: CFDictionary,
        _ result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus {
        switch copyResult {
        case .nothing: result?.pointee = nil
        case let .bytes(data): result?.pointee = data as CFData
        case let .notData(text): result?.pointee = text as CFString
        }
        return copyStatus
    }

    func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus { updateStatus }

    func add(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        addStatus
    }

    func delete(_ query: CFDictionary) -> OSStatus { deleteStatus }
}

@Suite("KeychainStore — when Security returns an OSStatus")
struct KeychainOSStatusTests {
    private let locked: OSStatus = errSecInteractionNotAllowed

    private func store(_ items: StubSecItems) -> KeychainStore {
        KeychainStore(service: "com.rajatslakhina.aichatapp.tests.stub", items: items)
    }

    @Test("an update that fails for a reason other than absence is surfaced, not retried as an add")
    func updateFailureIsNotSwallowed() {
        // If this fell through to `SecItemAdd` the app would report success while the value it
        // believes it stored is the old one — the failure mode the whole type exists to avoid.
        let subject = store(StubSecItems(updateStatus: locked, addStatus: errSecSuccess))
        #expect(throws: KeychainError.unexpectedStatus(locked)) {
            try subject.set("sk-or-v1-new", for: "k")
        }
    }

    @Test("an insert that fails after the item turned out to be absent is surfaced")
    func addFailureIsSurfaced() {
        let subject = store(StubSecItems(updateStatus: errSecItemNotFound, addStatus: locked))
        #expect(throws: KeychainError.unexpectedStatus(locked)) {
            try subject.set("sk-or-v1-new", for: "k")
        }
    }

    @Test("a delete that fails for a reason other than absence is surfaced")
    func deleteFailureIsSurfaced() {
        let subject = store(StubSecItems(deleteStatus: locked))
        #expect(throws: KeychainError.unexpectedStatus(locked)) {
            try subject.remove("k")
        }
    }

    @Test("a read that fails for a reason other than absence is surfaced")
    func readFailureIsSurfaced() {
        let subject = store(StubSecItems(copyStatus: locked))
        #expect(throws: KeychainError.unexpectedStatus(locked)) {
            _ = try subject.string(for: "k")
        }
    }

    /// Both halves of "the stored bytes are not a string": something that is not `Data` at all,
    /// and `Data` that is not valid UTF-8. Neither can be produced through this app's own writes,
    /// which is exactly why they are worth pinning — another process shares this Keychain.
    @Test("a value that is not UTF-8 text reports corruption rather than returning nothing")
    func corruptedValues() {
        let notData = store(StubSecItems(copyResult: .notData("text")))
        #expect(throws: KeychainError.dataCorrupted(account: "k")) {
            _ = try notData.string(for: "k")
        }

        let badBytes = store(StubSecItems(copyResult: .bytes(Data([0xC3, 0x28]))))
        #expect(throws: KeychainError.dataCorrupted(account: "k")) {
            _ = try badBytes.string(for: "k")
        }
    }

    @Test("an absent item still reads as nil through the seam")
    func absentReadsAsNil() throws {
        let subject = store(StubSecItems(copyStatus: errSecItemNotFound))
        #expect(try subject.string(for: "k") == nil)
    }
}

// MARK: - PreparedTurn equality

/// `LLMMessage` mints a fresh `UUID` on every construction, so the synthesized `==` would call two
/// structurally identical turns different. Every clause of the hand-written one is asserted here,
/// because a clause that is silently dropped makes two different turns compare equal — and that is
/// how a cached answer gets served for a question nobody asked.
@Suite("PreparedTurn equality")
struct PreparedTurnEqualityTests {
    private func turn(
        modelID: String = "openai/gpt-4o",
        messages: [LLMMessage] = [LLMMessage(role: .user, content: "hello")],
        outbound: String = "hello",
        display: String = "hello",
        sources: [RetrievedSource] = [],
        didCompact: Bool = false,
        tokens: Int = 4
    ) -> PreparedTurn {
        PreparedTurn(
            modelID: modelID,
            messages: messages,
            outboundUserText: outbound,
            displayUserText: display,
            sources: sources,
            didCompact: didCompact,
            estimatedInputTokens: tokens
        )
    }

    @Test("two structurally identical turns are equal despite fresh message identities")
    func identicalTurnsAreEqual() {
        #expect(turn() == turn())
        #expect(turn().messages[0].id != turn().messages[0].id, "the ids really do differ")
    }

    @Test("every field the provider would see makes two turns different")
    func everyFieldParticipates() {
        let source = RetrievedSource(id: "a", title: "a.md", snippet: "…", relevancePercent: 10)
        #expect(turn() != turn(modelID: "google/gemini-2.5-flash-lite"))
        #expect(turn() != turn(outbound: "hello there"))
        #expect(turn() != turn(display: "hello there"))
        #expect(turn() != turn(sources: [source]))
        #expect(turn() != turn(didCompact: true))
        #expect(turn() != turn(tokens: 5))
        #expect(turn() != turn(messages: [LLMMessage(role: .user, content: "goodbye")]))
        #expect(
            turn() != turn(messages: [LLMMessage(role: .assistant, content: "hello")]),
            "the same words in a different role are a different request"
        )
    }
}

// MARK: - Biometrics and the sign-in store

/// Biometrics that are present and answer however the test says.
private struct ScriptedBiometrics: BiometricAuthenticating {
    var isAvailable = true
    var displayName = "Face ID"
    var result: Result<Bool, any Error> = .success(true)

    func authenticate(reason: String) async throws -> Bool { try result.get() }
}

private struct BiometricRefusal: Error, LocalizedError {
    var errorDescription: String? { "the sensor is covered" }
}

@Suite("Biometric sign-in", .serialized)
@MainActor
struct BiometricAuthTests {
    /// `LAContext` cannot be driven from a test, which is why `BiometricAuthenticating` exists —
    /// but the concrete adapter still has to answer without trapping on a simulator that has no
    /// enrolled biometry. This is the only assertion that can honestly be made about it here.
    @Test("the real authenticator answers on a simulator with nothing enrolled")
    func realAuthenticatorIsInert() async {
        let authenticator = FaceIDAuthenticator()
        #expect(!authenticator.displayName.isEmpty)
        #expect(!authenticator.isAvailable, "no simulator used by this suite has biometry enrolled")
        do {
            let recognised = try await authenticator.authenticate(reason: "Unlock AI Chat")
            #expect(!recognised)
        } catch {
            #expect(error is LAError, "got \(error)")
        }
    }

    @Test("the unavailable stand-in never claims to recognise anyone")
    func unavailableStandIn() async throws {
        let biometrics = UnavailableBiometrics()
        #expect(!biometrics.isAvailable)
        #expect(biometrics.displayName == "Biometrics")
        #expect(try await biometrics.authenticate(reason: "Unlock") == false)
    }

    @Test("an empty passphrase is named as such rather than reported as a wrong password")
    func emptyPassphrase() {
        let auth = AuthStore(biometrics: UnavailableBiometrics(), persist: { _ in })
        auth.signIn(email: DemoAccount.email, passphrase: "")
        #expect(auth.failure == .emptyPassphrase)
        #expect(!auth.isSignedIn)
    }

    @Test("unlocking without biometrics enrolled says so, and does not sign anyone in")
    func unlockWithoutBiometrics() async {
        let auth = AuthStore(
            biometrics: ScriptedBiometrics(isAvailable: false, displayName: "Touch ID"),
            persist: { _ in }
        )
        await auth.unlockWithBiometrics()
        #expect(auth.failure == .biometricsUnavailable("Touch ID isn't set up on this device."))
        #expect(!auth.isSignedIn)
        #expect(!auth.isWorking, "the working flag must be cleared on every exit")
    }

    @Test("a recognised face signs in and persists the session")
    func unlockSucceeds() async {
        var persisted: [Bool] = []
        let auth = AuthStore(
            biometrics: ScriptedBiometrics(),
            persist: { persisted.append($0) }
        )
        #expect(auth.biometricsAvailable)
        #expect(auth.biometricsName == "Face ID")
        await auth.unlockWithBiometrics()
        #expect(auth.isSignedIn)
        #expect(auth.failure == nil)
        #expect(persisted == [true])
    }

    @Test("a face that is not recognised is a different failure from a sensor that broke")
    func unlockFailsAndThrows() async {
        let refused = AuthStore(
            biometrics: ScriptedBiometrics(result: .success(false)),
            persist: { _ in }
        )
        await refused.unlockWithBiometrics()
        #expect(refused.failure == .biometricsFailed("Face ID didn't recognise you."))

        let broken = AuthStore(
            biometrics: ScriptedBiometrics(result: .failure(BiometricRefusal())),
            persist: { _ in }
        )
        await broken.unlockWithBiometrics()
        #expect(broken.failure == .biometricsFailed("the sensor is covered"))
        #expect(!broken.isSignedIn, "a sensor error must never be read as a successful unlock")
    }

    /// The restored store outside a UI-test launch takes its default persistence, which is the one
    /// path that actually writes to `UserDefaults`. Signed back out at the end so the suite leaves
    /// the simulator's defaults as it found them.
    @Test("a normal launch restores from, and writes back to, UserDefaults")
    func restoredUsesDefaults() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: AuthStore.storageKey)

        let auth = AuthStore.restored(arguments: [], defaults: defaults)
        #expect(!auth.isSignedIn)
        auth.signIn(email: DemoAccount.email, passphrase: DemoAccount.passphrase)
        #expect(auth.isSignedIn)
        #expect(defaults.bool(forKey: AuthStore.storageKey))

        auth.signOut()
        #expect(!defaults.bool(forKey: AuthStore.storageKey))
        defaults.removeObject(forKey: AuthStore.storageKey)
    }
}

// MARK: - The executor's error vocabulary

@Suite("Turn executor — how failures are classified")
struct ExecutorClassificationTests {
    private func executor(scopes: BudgetScopes) -> TurnExecutor {
        TurnExecutor(
            provider: OpenRouterProvider(
                configuration: OpenRouterConfiguration(apiKey: "sk-or-v1-test"),
                session: .shared,
                usageObserver: UsageRecorder()
            ),
            idempotency: IdempotencyGuard(),
            profiler: WorkloadProfiler(),
            estimator: CostEstimator(priceBook: TestPriceBook.empty),
            governor: QuotaGovernor(),
            retryPolicy: ExponentialBackoffRetryPolicy(maxAttempts: 1),
            meter: TokenMeter(registry: PricingRegistry()),
            usage: UsageRecorder(),
            scopes: scopes
        )
    }

    private var scopes: BudgetScopes {
        BudgetScopes(account: ScopeID("account"), conversation: ScopeID("conversation"))
    }

    /// The distinction the whole design turns on: a provider that said no is a refusal the user can
    /// act on; anything else is a failure. Collapsing them is how an app says "something went
    /// wrong" about a rate limit.
    @Test("a provider error becomes a refusal; every other error becomes a failure")
    func failedClassifies() async {
        let subject = executor(scopes: scopes)
        var trace = PipelineTrace()
        let refused = await subject.failed(ProviderError.timeout, trace: &trace)
        guard case let .refused(refusal) = refused else {
            Issue.record("a ProviderError must refuse, got \(refused)")
            return
        }
        #expect(refusal.stage == .providerRouting)
        #expect(trace.outcome(for: .providerRouting)?.isRefusal == true)

        var second = PipelineTrace()
        let broke = await subject.failed(BiometricRefusal(), trace: &second)
        guard case let .failed(message) = broke else {
            Issue.record("a non-provider error must fail, got \(broke)")
            return
        }
        #expect(message.contains("BiometricRefusal"))
        #expect(second.outcome(for: .providerRouting)?.isFailure == true)
    }

    @Test("a timeout and a dropped connection are told apart, and both offer a retry")
    func providerRefusalsCoverEveryCase() {
        let timeout = TurnExecutor.refusal(for: ProviderError.timeout)
        #expect(timeout.headline == "The model took too long")
        #expect(timeout.recoveryTitle == "Try again")

        let dropped = TurnExecutor.refusal(for: ProviderError.connectionFailed("socket closed"))
        #expect(dropped.headline == "Couldn't reach OpenRouter")
        #expect(dropped.explanation == "socket closed")
        #expect(dropped.recoveryTitle == "Try again")

        let capability = TurnExecutor.refusal(
            for: ProviderError.capabilityMismatch("this model has no vision")
        )
        #expect(capability.headline == "This model can't handle that")
        #expect(capability.recoveryTitle == "Choose another model")
    }

    /// A double-tapped Send is not an error the user can do anything about, so the refusal has no
    /// recovery action — and a banner that offered one would be a button that resends the message
    /// already in flight.
    @Test("a duplicate send in flight refuses with no action attached")
    func idempotencyRefusal() {
        let refusal = TurnExecutor.refusal(
            for: IdempotencyError.requestInFlight(IdempotencyKey("k"))
        )
        #expect(refusal.stage == .idempotencyGuard)
        #expect(refusal.recovery == nil)
        #expect(refusal.recoveryTitle == nil)
    }

    @Test("every quota refusal explains itself, including the ones a demo rarely reaches")
    func quotaExplanations() {
        let scope = ScopeID("account")
        let arrears = TurnExecutor.explain(
            .exhausted(scope: scope, axis: .microcents, remaining: -400, requested: 1_000)
        )
        #expect(arrears.contains("overspent"), "got \(arrears)")

        #expect(TurnExecutor.explain(.quarantined(scope)).contains("paused"))
        #expect(
            TurnExecutor.explain(.fairShareExceeded(scope: scope, share: 3)).contains("share of 3")
        )
        #expect(
            TurnExecutor.explain(.concurrencyExhausted(scope: scope, limit: 2)).contains("limit of 2")
        )
        // The catch-all still has to say something rather than render an empty banner.
        #expect(!TurnExecutor.explain(.emptyPath).isEmpty)
    }

    /// The ledger is rebuilt whenever the ceiling changes, and a rebuild that fails must leave the
    /// old one in place rather than trap. Nothing in the composition root can produce these scopes;
    /// a settings screen that could would take the app down on the next send.
    @Test("a governor the package refuses to register comes back as nil, not as a trap")
    func makeGovernorReturnsNil() async {
        let broken = BudgetScopes(account: ScopeID(""), conversation: ScopeID("conversation"))
        #expect(await TurnExecutor.makeGovernor(scopes: broken, budget: MonthlyBudget()) == nil)
        #expect(await TurnExecutor.makeGovernor(scopes: scopes, budget: MonthlyBudget()) != nil)
    }

    /// A turn with no plan is a turn with no forecast, and a turn with no forecast reserves
    /// nothing. Reserving against an invented number would be worse than not reserving.
    @Test("no workload plan means the forecast is skipped rather than guessed")
    func missingPlanSkipsForecast() async {
        let subject = executor(scopes: scopes)
        var trace = PipelineTrace()
        #expect(await subject.forecastCost(nil, trace: &trace) == nil)
        #expect(trace.outcome(for: .costForecast)?.summary.contains("no plan") == true)

        var second = PipelineTrace()
        let hold = await subject.holdBudget(nil, trace: &second)
        #expect(hold.reservation == nil)
        #expect(second.outcome(for: .budgetReserve)?.summary.contains("no forecast") == true)
    }

    /// A run the profiler rejects is a run it should not learn from. The only way to produce one
    /// from a real turn is a provider that reported a negative token count, which is a thing an
    /// upstream can do and this app must not propagate into the plan for the next turn.
    @Test("a nonsensical token count is dropped rather than taught to the profiler")
    func profilerRejectsNonsense() async {
        let subject = executor(scopes: scopes)
        let turn = PreparedTurn(
            modelID: "openai/gpt-4o",
            messages: [],
            outboundUserText: "hello",
            displayUserText: "hello",
            sources: [],
            didCompact: false,
            estimatedInputTokens: 4
        )
        await subject.recordObservation(turn: turn, prompt: -5, completion: 12)
        await subject.recordObservation(turn: turn, prompt: 0, completion: 0)

        var trace = PipelineTrace()
        _ = await subject.forecastCost(
            TurnExecutor.declaredPlan(for: turn),
            trace: &trace
        )
        #expect(trace.outcome(for: .costForecast)?.isFailure == true, "no prices are registered")
    }
}

// MARK: - Composition fallbacks

@Suite("Composition — the fallbacks that keep a launch alive")
struct CompositionFallbackTests {
    /// An unlimited ledger is the honest fallback: pretending to enforce a limit the governor
    /// refused to accept would be worse than not enforcing it, and trapping would be worse still.
    @Test("a ledger the governor rejects falls back to an unlimited one rather than trapping")
    func governorFallback() async {
        let broken = BudgetScopes(account: ScopeID(""), conversation: ScopeID("conversation"))
        let governor = await Composition.makeGovernor(scopes: broken, budget: MonthlyBudget())
        #expect(await governor.reservations().isEmpty)
    }

    /// A registry that failed to bootstrap still answers — every lookup throws `.unknownContract`,
    /// the migration stage records a failure, and the conversation keeps its fallback title. That
    /// is a better launch than trapping over a navigation-bar caption.
    @Test("a schema registry that cannot be built is replaced by an empty one")
    func contractsFallback() async {
        let empty = await Composition.makeContracts { throw BiometricRefusal() }
        await #expect(throws: (any Error).self) {
            try await empty.coverage(of: MetadataSchema.contractID)
        }

        let real = await Composition.makeContracts()
        let coverage = try? await real.coverage(of: MetadataSchema.contractID)
        #expect(coverage != nil, "the real registry must still bootstrap")
    }

    /// Outside a UI-test launch the picker talks to the live `/models` endpoint. Nothing is sent
    /// here — the assertion is that the graph wires the network client rather than the fixture,
    /// which is the difference between a demo and an app.
    @Test("a normal launch wires the live catalogue client, not the UI-test fixture")
    func realCatalogOutsideUITests() async {
        let secrets = AppSecrets(store: InMemoryKeychain(), info: [:], launchArguments: [])
        let live = await Composition.build(apiKey: "sk-or-v1-test", secrets: secrets, arguments: [])
        #expect(live.catalog is ModelCatalogClient)

        let fixture = await Composition.build(
            apiKey: "sk-or-v1-test",
            secrets: secrets,
            arguments: ["-UITestMode"]
        )
        #expect(fixture.catalog is StaticModelCatalog)
    }

    /// The month's total is kept by the app because the governor's ledger is in memory. A graph
    /// built without a sink still has to settle turns; the default one discards.
    @Test("a graph built without a spend sink settles without complaining")
    func defaultSpendSink() async {
        let secrets = AppSecrets(store: InMemoryKeychain(), info: [:], launchArguments: [])
        let graph = await Composition.build(apiKey: "", secrets: secrets, arguments: [])
        await graph.executor.reportSpend(4_200)
        await graph.executor.reportSpend(0)
    }
}

// MARK: - Tool authority and dispatch edges

@Suite("Tool authority — when the broker disagrees")
struct ToolAuthorityEdgeTests {
    private func capabilities() -> [Capability] {
        ToolAuthorityGate.readOnly(tools: [DemoTools.calculatorName])
    }

    /// A denial is policy working. A thrown `AuthorityError` means this app's model of the policy
    /// disagrees with the broker's, which is a defect — and it must not be laundered into a
    /// denial, because a denial tells the user to approve something that would not help.
    @Test("a grant id already held reports a failure rather than a refusal")
    func brokerDisagreementIsAFailure() async throws {
        let broker = AuthorityBroker()
        // Occupy the id the gate will try to issue under, which is what a second gate over the
        // same broker would do.
        try await broker.issue(
            Grant(
                id: ToolAuthorityGate.grantID(for: "conversation-1"),
                principal: "someone-else",
                task: "chat",
                capabilities: capabilities(),
                maxUses: 1
            )
        )
        let gate = ToolAuthorityGate(capabilities: capabilities(), broker: broker)

        let verdict = await gate.decide(
            tool: DemoTools.calculatorName,
            arguments: #"{"expression":"1+1"}"#,
            conversationID: "conversation-1",
            provenance: .modelAuthored
        )
        guard case let .failed(message) = verdict else {
            Issue.record("expected a failure, got \(verdict)")
            return
        }
        #expect(message.contains("duplicateGrantID"), "got \(message)")
    }

    /// The round trip must stop on a failed verdict exactly as firmly as on a denial — but without
    /// raising a refusal, because there is nothing for the user to approve.
    @Test("a failed authority verdict stops the call without pretending it was refused")
    func failedVerdictStopsDispatch() async throws {
        let broker = AuthorityBroker()
        try await broker.issue(
            Grant(
                id: ToolAuthorityGate.grantID(for: "conversation-2"),
                principal: "someone-else",
                task: "chat",
                capabilities: capabilities(),
                maxUses: 1
            )
        )
        let registry = ToolRegistryKit.ToolRegistry()
        await registry.register(DemoTools.calculator, handler: DemoTools.calculatorHandler())
        let round = ToolRoundTrip(
            registry: registry,
            gate: ToolAuthorityGate(capabilities: capabilities(), broker: broker)
        )

        let resolution = await round.resolve(
            id: "call-1",
            toolName: DemoTools.calculatorName,
            argumentsJSON: Data(#"{"expression":"1+1"}"#.utf8),
            in: ToolCallContext(conversationID: "conversation-2", provenance: .modelAuthored)
        )

        #expect(resolution.observation == nil)
        #expect(resolution.refusal == nil, "a failure is not a refusal and must not be dressed as one")
        #expect(resolution.records.first?.outcome.isFailure == true)
        #expect(await round.statistics().totalCalls == 0, "the registry must never be reached")
    }

    /// Cancelling mid-turn must not be reported as a tool that threw: `ToolRegistry` catches
    /// `CancellationError` with the same `catch` as any other error, which would show the user a
    /// failure that did not happen and permanently skew statistics that have no reset.
    @Test("a cancelled turn skips dispatch instead of reporting a handler that threw")
    func cancellationSkipsDispatch() async throws {
        let registry = ToolRegistryKit.ToolRegistry()
        await registry.register(DemoTools.calculator, handler: DemoTools.calculatorHandler())
        let round = ToolRoundTrip(
            registry: registry,
            gate: ToolAuthorityGate(capabilities: capabilities())
        )

        let task = Task {
            await round.resolve(
                id: "call-1",
                toolName: DemoTools.calculatorName,
                argumentsJSON: Data(#"{"expression":"1+1"}"#.utf8),
                in: ToolCallContext(conversationID: "cancelled", provenance: .modelAuthored)
            )
        }
        task.cancel()
        let resolution = await task.value

        #expect(resolution.activity == .cleared(tool: DemoTools.calculatorName))
        #expect(resolution.result == nil)
        let dispatch = resolution.records.first { $0.stage == .toolDispatch }
        #expect(dispatch?.outcome.summary.contains("cancelled") == true)
        #expect(await round.statistics().totalCalls == 0)
    }
}

// MARK: - Small surfaces with real rules in them

@Suite("Odds and ends that still decide something")
struct RemainingSurfaceTests {
    /// `StageRecord` is what `ForEach` identifies rows by. Two records for one stage — which the
    /// Diagnostics screen deliberately shows both of — therefore share an id, and that is the
    /// reason the list keys on the array index rather than on this.
    @Test("a stage record identifies itself by its stage")
    func stageRecordIdentity() {
        let record = StageRecord(stage: .budgetReserve, outcome: .ran(detail: "held"), durationMs: 1)
        #expect(record.id == PipelineStage.budgetReserve.rawValue)
        #expect(record.id == "budgetReserve")
    }

    /// A leading `+` is not decoration — models emit `+5` and `3 * +4` — and an evaluator that
    /// rejected it would send an arithmetic error back for an expression that is plainly valid.
    @Test("unary plus is accepted wherever unary minus is")
    func unaryPlus() throws {
        #expect(try ArithmeticEvaluator.evaluate("+5") == 5)
        #expect(try ArithmeticEvaluator.evaluate("3 * +4") == 12)
        #expect(try ArithmeticEvaluator.evaluate("+(2 + 3)") == 5)
    }

    /// The initializer that reads `Bundle.main` has to cope with a bundle that has no info
    /// dictionary at all, which is what an app extension and a bare test host both look like.
    @Test("a nil info dictionary reads as no configuration rather than crashing")
    func nilInfoDictionary() {
        var secrets = AppSecrets(
            store: InMemoryKeychain(),
            infoDictionary: nil,
            launchArguments: []
        )
        #expect(secrets.resolveAPIKey() == nil)
        #expect(secrets.siteURL == nil)
        #expect(secrets.appName == nil)
    }

    /// Retrieval chunks come from anywhere, and only some carry a filename. The document id is the
    /// honest fallback for a source chip; a blank one would be a chip nobody can trace.
    @Test("a retrieved chunk with no filename falls back to its document id")
    func retrievedSourceFallback() {
        let named = ScoredChunk(
            chunk: StoredChunk(
                id: "c1",
                documentID: "doc-7",
                text: String(repeating: "a", count: 400),
                embedding: Embedding(vector: [1]),
                metadata: ["filename": "france.md"]
            ),
            score: 0.91
        )
        #expect(RetrievedSource(named).title == "france.md")
        #expect(RetrievedSource(named).snippet.count == 160, "the snippet is capped")

        let anonymous = ScoredChunk(
            chunk: StoredChunk(
                id: "c2",
                documentID: "doc-8",
                text: "short",
                embedding: Embedding(vector: [1])
            ),
            score: 1.4
        )
        #expect(RetrievedSource(anonymous).title == "doc-8")
        #expect(RetrievedSource(anonymous).relevancePercent == 100, "a score over 1 is clamped")
    }

    /// The two flags a model can omit entirely, plus an architecture block that is absent. A
    /// catalogue entry missing them must read as "cannot do this", never as a crash and never as
    /// an optimistic yes.
    @Test("a catalogue entry that declares nothing is reported as capable of nothing")
    func modelWithNoDeclarations() {
        let bare = OpenRouterModel(
            id: "vendor/bare",
            name: nil,
            contextLength: nil,
            pricing: .init(prompt: "0.000001", completion: "0.000002", inputCacheRead: nil),
            architecture: nil,
            supportedParameters: nil,
            topProvider: nil
        )
        #expect(!bare.supportsToolCalling)
        #expect(!bare.supportsStructuredOutputs)
        #expect(!bare.supportsVision)
        #expect(bare.displayName == "vendor/bare", "the slug stands in for a missing name")
        #expect(bare.isSelectableWithKnownCost)
    }

    /// Both remaining pipeline toggles, and the persistence path a real launch takes. The store
    /// writes through on every change, because a setting that only survives while the screen is
    /// open is worse than one that was never offered.
    @Test("the memory and retrieval toggles write through to persistence")
    @MainActor
    func settingsTogglesPersist() throws {
        let defaults = try #require(UserDefaults(suiteName: "settings.tests.\(UUID().uuidString)"))
        let persistence = UserDefaultsSettings(defaults: defaults)
        let store = AppSettingsStore(persistence: persistence)

        store.retrievalEnabled = false
        store.memoryEnabled = false
        #expect(!store.snapshot.pipeline.retrievalEnabled)
        #expect(!store.snapshot.pipeline.memoryEnabled)
        #expect(persistence.loadSettings() != nil, "the change reached UserDefaults")

        let reloaded = AppSettingsStore(persistence: persistence)
        #expect(!reloaded.retrievalEnabled)
        #expect(!reloaded.memoryEnabled)
        defaults.removePersistentDomain(forName: defaults.description)
    }

    /// The hop off whatever actor settled the turn and onto the main actor, where the month's
    /// total lives. A settled turn that never reaches the store is a budget that resets on relaunch.
    @Test("a settled turn's cost reaches the month's running total")
    @MainActor
    func spendRecorderReachesTheStore() async {
        let store = AppSettingsStore(persistence: InMemorySettings())
        let record = RootView.spendRecorder(for: store)
        record(4_200)
        for _ in 0..<200 where store.budget.spentMicrocents == 0 {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        #expect(store.budget.spentMicrocents == 4_200)
    }
}

// MARK: - The stand-in a refusing Keychain launch uses

/// `RejectingKeychain` ships in `Sources` so a XCUITest can see what Settings says when a write is
/// refused. It has to behave like a Keychain that is present and unhappy, not like one that is
/// absent — a store that quietly succeeded on `remove` would let "Delete key" report success on a
/// device where nothing can be written at all.
@Suite("The refusing Keychain stand-in")
struct RejectingKeychainTests {
    @Test("every write is refused, and a read comes back empty rather than throwing")
    func refusesWritesButNotReads() throws {
        let store = RejectingKeychain()
        #expect(try store.string(for: AppSecrets.apiKeyAccount) == nil)
        #expect(throws: KeychainError.unexpectedStatus(store.status)) {
            try store.set("sk-or-v1-anything", for: AppSecrets.apiKeyAccount)
        }
        #expect(throws: KeychainError.unexpectedStatus(store.status)) {
            try store.remove(AppSecrets.apiKeyAccount)
        }
    }

    /// The launch that installs it. Without the flag the in-memory store is used, and with it the
    /// app resolves to no key at all — which is what makes the Settings error the only thing on
    /// screen that has changed.
    @Test("the launch flag is what swaps the store, and only that flag")
    @MainActor
    func launchFlagSwapsTheStore() {
        let refusing = AppEnvironment.forLaunch(arguments: ["-UITestMode", "-FailKeychainWrites"])
        #expect(!refusing.hasAPIKey)
        #expect(throws: (any Error).self) { try refusing.updateAPIKey("sk-or-v1-anything") }

        let ordinary = AppEnvironment.forLaunch(arguments: ["-UITestMode"])
        #expect(!ordinary.hasAPIKey)
        try? ordinary.updateAPIKey("sk-or-v1-abcdefgh1234")
        #expect(ordinary.hasAPIKey, "the in-memory store accepts what the refusing one will not")
    }
}
