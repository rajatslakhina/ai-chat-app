import SwiftUI

/// Process-wide configuration resolved once at launch.
///
/// `@Observable` rather than a singleton so that tests and previews can hand the view tree a
/// different environment without the real Keychain being touched.
@MainActor
@Observable
final class AppEnvironment {
    private(set) var secrets: AppSecrets
    private(set) var apiKey: String?

    /// Bumped whenever the key changes, so the view tree can rebuild the object graph around it.
    ///
    /// Necessary rather than tidy: `OpenRouterConfiguration` captures the key when the provider is
    /// constructed, so a key replaced in Settings would otherwise take effect only on the next
    /// launch — and the user would sit watching 401s from a key they had just fixed.
    private(set) var keyRevision = 0

    var hasAPIKey: Bool { apiKey?.isEmpty == false }
    var secretOrigin: SecretOrigin { secrets.origin }

    /// The key as Settings shows it: enough to recognise, not enough to spend.
    var maskedAPIKey: String? {
        guard let apiKey, !apiKey.isEmpty else { return nil }
        return AppSecrets.mask(apiKey)
    }

    init(secrets: AppSecrets = AppSecrets()) {
        var resolved = secrets
        self.apiKey = resolved.resolveAPIKey()
        self.secrets = resolved
    }

    /// Replaces the key from Settings and re-resolves, so `origin` stops claiming the value
    /// came from the build once the user has overridden it.
    func updateAPIKey(_ value: String) throws {
        try secrets.updateAPIKey(value)
        var resolved = secrets
        apiKey = resolved.resolveAPIKey()
        secrets = resolved
        keyRevision += 1
    }

    /// A UI-test launch puts the app into a deterministic state: no device Keychain, no
    /// inherited session. Without this a passing test on a clean machine fails on a machine
    /// where a previous run left a key behind.
    static func forLaunch(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> AppEnvironment {
        guard arguments.contains("-UITestMode") else { return AppEnvironment() }
        // `-FailKeychainWrites` is the only way to see what Settings says when a write is refused.
        // A locked device really does return `errSecInteractionNotAllowed`, and the alternative to
        // this flag is an error message nobody has ever read.
        let store: any SecretStoring = arguments.contains("-FailKeychainWrites")
            ? RejectingKeychain()
            : InMemoryKeychain()
        return AppEnvironment(
            secrets: AppSecrets(store: store, info: [:], launchArguments: arguments)
        )
    }
}

@main
struct AIChatAppMain: App {
    @State private var environment = AppEnvironment.forLaunch()
    @State private var auth = AuthStore.restored()
    @State private var settings = AppSettingsStore.forLaunch()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .environment(auth)
                .environment(settings)
        }
    }
}

extension AppSettingsStore {
    /// A UI-test launch keeps its settings in memory, for the same reason it keeps its Keychain
    /// there: a run that inherited the previous run's model choice or spend total passes on this
    /// machine and fails on the next one.
    static func forLaunch(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> AppSettingsStore {
        guard arguments.contains("-UITestMode") else { return AppSettingsStore() }
        return AppSettingsStore(persistence: InMemorySettings())
    }
}

/// Chooses between the login gate and the app itself.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AuthStore.self) private var auth
    @Environment(AppSettingsStore.self) private var settings
    @State private var composition: Composition?
    @State private var model: ChatViewModel?

    /// What a rebuild depends on. Signing out and back in, or replacing the key, both invalidate
    /// the whole graph — the provider captured the old credential when it was constructed.
    private struct GraphIdentity: Equatable {
        let signedIn: Bool
        let keyRevision: Int
    }

    var body: some View {
        Group {
            if !auth.isSignedIn {
                LoginView()
                    .transition(.opacity)
            } else if let composition, let model {
                ChatScaffold(composition: composition, model: model)
                    .transition(.opacity)
            } else {
                ProgressView("Starting…")
                    .accessibilityIdentifier("startingIndicator")
            }
        }
        .animation(.easeInOut(duration: 0.2), value: auth.isSignedIn)
        .task(
            id: GraphIdentity(signedIn: auth.isSignedIn, keyRevision: environment.keyRevision)
        ) {
            guard auth.isSignedIn else { return }
            await start()
        }
    }

    /// The sink a settled turn's real cost goes to.
    ///
    /// A named function rather than a closure literal inside `start()` because `start()` needs a
    /// whole object graph and a network call to run, and this hop — off whatever actor settled the
    /// turn, onto the main actor, into the month's running total — is the part with a rule in it.
    static func spendRecorder(for settings: AppSettingsStore) -> @Sendable (Int) -> Void {
        { microcents in
            Task { @MainActor in settings.recordSpend(microcents: microcents) }
        }
    }

    private func start() async {
        let built = await Composition.build(
            apiKey: environment.apiKey ?? "",
            secrets: environment.secrets,
            budget: settings.budget,
            onSettled: Self.spendRecorder(for: settings)
        )
        composition = built
        model = ChatViewModel(
            pipeline: built.pipeline,
            executor: built.executor,
            review: built.review,
            metadata: built.metadata,
            tools: built.tools
        )
        // The saved settings reach the actors before the first send, not on the first change: a
        // graph built from defaults would answer one turn with the wrong model and the wrong
        // temperature, and the user would have no way to know it had happened.
        await settings.connect(to: built)
        // Prices land after the UI is up. Until they do, costs read as "not reported" rather than
        // as a confident zero.
        await built.installPricing()
    }
}
