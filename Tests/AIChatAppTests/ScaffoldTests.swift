import Testing
@testable import AIChatApp

/// Proves the secrets precedence chain end to end without touching the device Keychain.
@Suite("AppSecrets precedence")
struct AppSecretsTests {
    @Test("a build-supplied key is promoted into the Keychain and then owned by it")
    func promotesBuildKey() throws {
        let store = InMemoryKeychain()
        var secrets = AppSecrets(store: store, info: ["OpenRouterAPIKey": "sk-or-v1-build"])

        #expect(secrets.resolveAPIKey() == "sk-or-v1-build")
        #expect(secrets.origin == .buildConfiguration)
        #expect(try store.string(for: AppSecrets.apiKeyAccount) == "sk-or-v1-build")

        var second = AppSecrets(store: store, info: ["OpenRouterAPIKey": "sk-or-v1-build"])
        #expect(second.resolveAPIKey() == "sk-or-v1-build")
        #expect(second.origin == .keychain, "once promoted, the Keychain is the source of truth")
    }

    @Test("a key set on device beats the one baked into the build")
    func keychainWinsOverBuild() throws {
        let store = InMemoryKeychain(seed: [AppSecrets.apiKeyAccount: "sk-or-v1-user"])
        var secrets = AppSecrets(store: store, info: ["OpenRouterAPIKey": "sk-or-v1-build"])
        #expect(secrets.resolveAPIKey() == "sk-or-v1-user")
        #expect(secrets.origin == .keychain)
    }

    @Test("an unexpanded xcconfig token reads as absent, never as a bearer token")
    func unexpandedTokenIsAbsent() {
        var secrets = AppSecrets(store: InMemoryKeychain(), info: ["OpenRouterAPIKey": "$(OPENROUTER_API_KEY)"])
        #expect(secrets.resolveAPIKey() == nil)
        #expect(secrets.origin == .absent)
    }

    @Test("a fresh clone with no Secrets.xcconfig still resolves, to nothing")
    func missingConfigIsALegalState() {
        var secrets = AppSecrets(store: InMemoryKeychain(), info: [:])
        #expect(secrets.resolveAPIKey() == nil)
        #expect(secrets.origin == .absent)
    }

    @Test("clearing the key in Settings removes it rather than storing blank")
    func clearingRemoves() throws {
        let store = InMemoryKeychain(seed: [AppSecrets.apiKeyAccount: "sk-or-v1-user"])
        let secrets = AppSecrets(store: store, info: [:])
        try secrets.updateAPIKey("   ")
        #expect(try store.string(for: AppSecrets.apiKeyAccount) == nil)
    }

    @Test("a test-harness launch argument overrides everything and never reads the device")
    func launchArgumentWins() {
        let store = InMemoryKeychain(seed: [AppSecrets.apiKeyAccount: "sk-or-v1-user"])
        var secrets = AppSecrets(
            store: store,
            info: ["OpenRouterAPIKey": "sk-or-v1-build"],
            launchArguments: [AppSecrets.testKeyLaunchArgument, "sk-or-v1-test"]
        )
        #expect(secrets.resolveAPIKey() == "sk-or-v1-test")
        #expect(secrets.origin == .testHarness)
    }
}
