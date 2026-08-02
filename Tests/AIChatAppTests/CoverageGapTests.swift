import Foundation
import ProviderGatewayKit
import StreamAggregatorKit
import Testing
@testable import AIChatApp

/// Exercises the real Keychain on the simulator.
///
/// Every test uses a unique service name. The simulator's Keychain persists across test runs and
/// is shared by every suite in the process, so a fixed service would let one run's leftovers
/// decide another run's result — the exact flakiness `InMemoryKeychain` exists to avoid elsewhere.
@Suite("KeychainStore against the real Keychain", .serialized)
struct KeychainStoreTests {
    private func makeStore() -> KeychainStore {
        KeychainStore(service: "com.rajatslakhina.aichatapp.tests.\(UUID().uuidString)")
    }

    @Test("a value round-trips")
    func roundTrip() throws {
        let store = makeStore()
        #expect(try store.string(for: "k") == nil, "an unset account reads as nil, not empty")

        try store.set("sk-or-v1-abc", for: "k")
        #expect(try store.string(for: "k") == "sk-or-v1-abc")
    }

    @Test("setting twice updates rather than duplicating")
    func updateExisting() throws {
        let store = makeStore()
        try store.set("first", for: "k")
        try store.set("second", for: "k")
        #expect(try store.string(for: "k") == "second")
    }

    @Test("removing is idempotent — deleting what is not there is not an error")
    func removeIsIdempotent() throws {
        let store = makeStore()
        try store.set("value", for: "k")
        try store.remove("k")
        #expect(try store.string(for: "k") == nil)
        try store.remove("k")
    }

    @Test("accounts are isolated from one another")
    func accountsAreSeparate() throws {
        let store = makeStore()
        try store.set("a", for: "one")
        try store.set("b", for: "two")
        #expect(try store.string(for: "one") == "a")
        #expect(try store.string(for: "two") == "b")
    }

    @Test("errors describe themselves rather than surfacing a bare OSStatus")
    func errorDescriptions() {
        #expect(!KeychainError.unexpectedStatus(-25300).description.isEmpty)
        #expect(KeychainError.dataCorrupted(account: "k").description.contains("UTF-8"))
        #expect(KeychainError.unexpectedStatus(-25300) == .unexpectedStatus(-25300))
    }
}

@Suite("Usage aggregation")
struct UsageRecorderTests {
    private func usage(prompt: Int, completion: Int, cost: Double?) -> OpenRouterUsage {
        OpenRouterUsage(
            requestID: nil,
            model: "m",
            promptTokens: prompt,
            completionTokens: completion,
            cachedPromptTokens: 0,
            reportedCostUSD: cost
        )
    }

    @Test("totals accumulate across calls")
    func totals() async {
        let recorder = UsageRecorder()
        await recorder.record(usage(prompt: 10, completion: 5, cost: 0.001))
        await recorder.record(usage(prompt: 20, completion: 7, cost: 0.002))

        let prompt = await recorder.totalPromptTokens
        let completion = await recorder.totalCompletionTokens
        let cost = await recorder.reportedCostUSD
        #expect(prompt == 30)
        #expect(completion == 12)
        #expect(cost == 0.003)
    }

    @Test("a mix of reported and unreported costs sums only what was reported")
    func partialCosts() async {
        let recorder = UsageRecorder()
        await recorder.record(usage(prompt: 1, completion: 1, cost: nil))
        await recorder.record(usage(prompt: 1, completion: 1, cost: 0.005))
        let cost = await recorder.reportedCostUSD
        #expect(cost == 0.005)
    }

    @Test("reset clears history")
    func reset() async {
        let recorder = UsageRecorder()
        await recorder.record(usage(prompt: 1, completion: 1, cost: 0.1))
        await recorder.reset()

        let records = await recorder.records
        let cost = await recorder.reportedCostUSD
        #expect(records.isEmpty)
        #expect(cost == nil)
    }

    @Test("the null observer accepts and discards")
    func nullObserver() async {
        await NullUsageObserver().record(usage(prompt: 1, completion: 1, cost: 0.1))
    }

    @Test("total tokens is the sum of both axes")
    func totalTokens() {
        #expect(usage(prompt: 3, completion: 4, cost: nil).totalTokens == 7)
    }
}

@Suite("JSON bridging")
struct JSONValueTests {
    @Test("every case round-trips through encode and decode")
    func roundTrip() throws {
        let value = OpenRouterJSON.object([
            "string": .string("s"),
            "int": .int(3),
            "double": .double(1.5),
            "bool": .bool(true),
            "null": .null,
            "array": .array([.int(1), .string("two"), .null]),
            "nested": .object(["inner": .bool(false)])
        ])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(OpenRouterJSON.self, from: data)
        #expect(decoded == value)
    }

    @Test("gateway tool arguments convert both ways without loss")
    func toolArgumentBridging() {
        let original: LLMToolArgumentValue = .object([
            "s": .string("x"),
            "i": .int(1),
            "d": .double(2.5),
            "b": .bool(false),
            "n": .null,
            "a": .array([.int(1), .string("y")]),
            "o": .object(["k": .bool(true)])
        ])
        #expect(OpenRouterJSON(original).asToolArgument == original)
    }

    @Test("a value JSON cannot represent is rejected rather than silently dropped")
    func rejectsNonJSON() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(OpenRouterJSON.self, from: Data("<xml/>".utf8))
        }
    }
}

@Suite("Secrets edge cases")
struct AppSecretsEdgeTests {
    @Test("site URL and app name read from the build configuration")
    func optionalMetadata() {
        let secrets = AppSecrets(
            store: InMemoryKeychain(),
            info: [
                "OpenRouterSiteURL": "https://example.test",
                "OpenRouterAppName": "AI Chat"
            ]
        )
        #expect(secrets.siteURL == "https://example.test")
        #expect(secrets.appName == "AI Chat")
    }

    @Test("an unsubstituted or blank metadata value reads as absent")
    func blankMetadata() {
        let secrets = AppSecrets(
            store: InMemoryKeychain(),
            info: ["OpenRouterSiteURL": "  ", "OpenRouterAppName": "$(OPENROUTER_APP_NAME)"]
        )
        #expect(secrets.siteURL == nil)
        #expect(secrets.appName == nil)
    }

    @Test("a launch flag with no value clears the key rather than storing the next argument")
    func launchFlagWithoutValue() {
        var secrets = AppSecrets(
            store: InMemoryKeychain(seed: [AppSecrets.apiKeyAccount: "stored"]),
            info: [:],
            launchArguments: [AppSecrets.testKeyLaunchArgument]
        )
        #expect(secrets.resolveAPIKey() == nil)
        #expect(secrets.origin == .testHarness)
    }

    @Test("updating writes through and the next resolve reads it back")
    func updateThenResolve() throws {
        let store = InMemoryKeychain()
        var secrets = AppSecrets(store: store, info: [:])
        try secrets.updateAPIKey("  sk-or-v1-trimmed  ")
        #expect(secrets.resolveAPIKey() == "sk-or-v1-trimmed", "surrounding whitespace is trimmed")
    }

    @Test("every origin has user-facing text")
    func originDescriptions() {
        let origins: [SecretOrigin] = [.keychain, .buildConfiguration, .testHarness, .absent]
        for origin in origins {
            #expect(!origin.settingsDescription.isEmpty)
        }
        #expect(SecretOrigin.absent.settingsDescription == "Not configured")
    }
}

@Suite("App environment")
@MainActor
struct AppEnvironmentTests {
    @Test("resolves a key at launch and reports where it came from")
    func resolvesAtLaunch() {
        let environment = AppEnvironment(
            secrets: AppSecrets(
                store: InMemoryKeychain(),
                info: ["OpenRouterAPIKey": "sk-or-v1-build"]
            )
        )
        #expect(environment.hasAPIKey)
        #expect(environment.secretOrigin == .buildConfiguration)
    }

    @Test("updating the key re-resolves, so the origin stops claiming the build supplied it")
    func updateChangesOrigin() throws {
        let environment = AppEnvironment(
            secrets: AppSecrets(
                store: InMemoryKeychain(),
                info: ["OpenRouterAPIKey": "sk-or-v1-build"]
            )
        )
        try environment.updateAPIKey("sk-or-v1-user")

        #expect(environment.apiKey == "sk-or-v1-user")
        #expect(environment.secretOrigin == .keychain)
    }

    @Test("clearing the key leaves the app usable, in the absent state")
    func clearingIsSurvivable() throws {
        let environment = AppEnvironment(
            secrets: AppSecrets(
                store: InMemoryKeychain(seed: [AppSecrets.apiKeyAccount: "sk"]),
                info: [:]
            )
        )
        try environment.updateAPIKey("")
        #expect(!environment.hasAPIKey)
        #expect(environment.secretOrigin == .absent)
    }

    @Test("a UI-test launch never reads the device Keychain")
    func uiTestLaunchIsIsolated() {
        let environment = AppEnvironment(
            secrets: AppSecrets(
                store: InMemoryKeychain(),
                info: [:],
                launchArguments: ["-UITestMode", AppSecrets.testKeyLaunchArgument, "sk-or-v1-fake"]
            )
        )
        #expect(environment.apiKey == "sk-or-v1-fake")
        #expect(environment.secretOrigin == .testHarness)
    }
}

@Suite("Provider mapping edges")
struct ProviderEdgeTests {
    @Test("the default capabilities describe a network provider that can do tools")
    func defaultCapabilities() {
        let capabilities = ProviderCapabilities.openRouterDefault
        #expect(capabilities.supportsToolCalling)
        #expect(capabilities.supportsStreaming)
        #expect(capabilities.locality == .network)
        #expect(capabilities.maxContextTokens == 128_000)
    }

    @Test("the provider identifier is stable")
    func identifier() {
        #expect(ProviderIdentifier.openRouter.rawValue == "openrouter")
    }

    @Test("finish reasons map from both the buffered and streamed vocabularies")
    func finishReasonMapping() {
        #expect(OpenRouterProvider.finishReason(for: "length") == .maxTokens)
        #expect(OpenRouterProvider.finishReason(for: "stop") == .stop)
        #expect(OpenRouterProvider.finishReason(for: nil as String?) == .stop)
        #expect(OpenRouterProvider.finishReason(for: "tool_calls") == .stop)

        let length = StreamAggregatorKit.FinishReason.length
        let stop = StreamAggregatorKit.FinishReason.stop
        #expect(OpenRouterProvider.finishReason(for: length) == .maxTokens)
        #expect(OpenRouterProvider.finishReason(for: stop) == .stop)
        #expect(OpenRouterProvider.finishReason(for: nil as StreamAggregatorKit.FinishReason?) == .stop)
    }

    @Test("an assembled message with no tool calls becomes text")
    func assembledTextOutcome() {
        let message = AssembledMessage(
            role: "assistant",
            content: "hello",
            toolCalls: [],
            finishReason: .stop,
            usage: nil
        )
        #expect(OpenRouterProvider.outcome(from: message) == .text("hello", .stop))
    }

    @Test("a tool call with no name is not treated as a call")
    func namelessToolCallIsNotACall() {
        let message = AssembledMessage(
            role: "assistant",
            content: "fallback",
            toolCalls: [AssembledToolCall(index: 0, id: "x", name: "", arguments: "{}")],
            finishReason: .stop,
            usage: nil
        )
        #expect(OpenRouterProvider.outcome(from: message) == .text("fallback", .stop))
    }

    @Test("a response with no choices is a transport failure, not an empty answer")
    func noChoices() {
        let json = #"{"choices":[]}"#
        #expect(throws: (any Error).self) {
            let response = try JSONDecoder().decode(
                OpenRouterChatResponse.self,
                from: Data(json.utf8)
            )
            _ = try OpenRouterProvider.outcome(from: response)
        }
    }

    @Test("a Retry-After that is not a number is treated as absent")
    func malformedRetryAfter() throws {
        let response = try #require(
            HTTPURLResponse(
                url: OpenRouterTestFixtures.fallbackURL,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": "soon"]
            )
        )
        #expect(OpenRouterProvider.retryAfter(from: response) == nil)
    }

    @Test("a negative Retry-After is rejected rather than producing a negative delay")
    func negativeRetryAfter() throws {
        let response = try #require(
            HTTPURLResponse(
                url: OpenRouterTestFixtures.fallbackURL,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": "-5"]
            )
        )
        #expect(OpenRouterProvider.retryAfter(from: response) == nil)
    }
}

@Suite("SSE framing edges")
struct SSEParserEdgeTests {
    @Test("non-data fields are ignored")
    func ignoresOtherFields() {
        #expect(SSEParser.frames(in: "event: message\nid: 7\ndata: x\n\n") == [.data("x")])
    }

    @Test("a line with no colon carries nothing this client needs")
    func bareLine() {
        #expect(SSEParser.frames(in: "keepalive\n\n").isEmpty)
    }

    @Test("an empty data payload produces no frame")
    func emptyData() {
        #expect(SSEParser.frames(in: "data:\n\n").isEmpty)
    }

    @Test("the byte accumulator cuts on newline and strips a trailing carriage return")
    func lineAccumulator() {
        var accumulator = SSELineAccumulator()
        var lines: [String] = []
        for byte in Array("ab\r\ncd\n".utf8) {
            if let line = accumulator.feed(byte) { lines.append(line) }
        }
        #expect(lines == ["ab", "cd"])
        #expect(accumulator.drain() == nil, "nothing pending after a trailing newline")
    }

    @Test("the accumulator drains a final line that had no newline")
    func accumulatorDrain() {
        var accumulator = SSELineAccumulator()
        for byte in Array("tail".utf8) { _ = accumulator.feed(byte) }
        #expect(accumulator.drain() == "tail")
        #expect(accumulator.drain() == nil)
    }
}

@Suite("Stream chunk edges")
struct StreamChunkEdgeTests {
    @Test("a chunk with no choices and no usage produces no deltas")
    func emptyChunk() throws {
        let chunk = try JSONDecoder().decode(
            OpenRouterStreamChunk.self,
            from: Data(#"{"id":"x"}"#.utf8)
        )
        #expect(chunk.streamDeltas.isEmpty)
        #expect(chunk.openRouterUsage(fallbackModel: "m") == nil)
    }

    @Test("usage falls back to the configured model when the chunk omits one")
    func usageModelFallback() throws {
        let json = #"{"usage":{"prompt_tokens":1,"completion_tokens":2}}"#
        let chunk = try JSONDecoder().decode(OpenRouterStreamChunk.self, from: Data(json.utf8))
        let usage = try #require(chunk.openRouterUsage(fallbackModel: "configured/model"))
        #expect(usage.model == "configured/model")
        #expect(usage.cachedPromptTokens == 0)
        #expect(usage.reportedCostUSD == nil)
    }

    @Test("a tool fragment with no arguments contributes an empty fragment, not nil")
    func toolFragmentWithoutArguments() throws {
        let json = #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"f"}}]}}]}"#
        let chunk = try JSONDecoder().decode(OpenRouterStreamChunk.self, from: Data(json.utf8))
        #expect(
            chunk.streamDeltas == [
                .toolCall(index: 0, id: "a", name: "f", argumentsFragment: "")
            ]
        )
    }
}
