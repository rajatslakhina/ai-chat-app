import Foundation
import ProviderGatewayKit
import Testing
@testable import AIChatApp

/// Tests that reach the real OpenRouter API.
///
/// Disabled unless `RUN_LIVE_OPENROUTER_TESTS=1` and `OPENROUTER_API_KEY` are both set in the
/// scheme or the `xcodebuild` invocation. Two reasons, and both matter:
///
/// - They spend real credit. A test suite that bills the account on every CI run is a test suite
///   people start skipping.
/// - They depend on a third party being up. A red build caused by someone else's outage teaches
///   the team to ignore red builds.
///
/// What they buy in exchange is the one thing stubs cannot: proof that the request this app
/// actually builds is accepted by the server that actually exists. Run them by hand when the
/// transport changes.
///
///     xcodebuild test … \
///       RUN_LIVE_OPENROUTER_TESTS=1 \
///       -only-testing:AIChatAppTests/LiveOpenRouterTests
struct LiveOpenRouterTests {
    private static var liveKey: String? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_LIVE_OPENROUTER_TESTS"] == "1" else { return nil }
        guard let key = environment["OPENROUTER_API_KEY"], !key.isEmpty else { return nil }
        return key
    }

    static var isEnabled: Bool { liveKey != nil }

    private let recorder = UsageRecorder()

    private func makeProvider(streaming: Bool) throws -> OpenRouterProvider {
        let key = try #require(Self.liveKey)
        return OpenRouterProvider(
            configuration: OpenRouterConfiguration(
                apiKey: key,
                model: "openai/gpt-4o",
                siteURL: "https://github.com/rajatslakhina/ai-chat-app",
                appName: "AI Chat (tests)",
                streaming: streaming
            ),
            session: .shared,
            usageObserver: recorder
        )
    }

    private var request: LLMRequest {
        LLMRequest(
            messages: [
                LLMMessage(role: .system, content: "Reply with exactly one word."),
                LLMMessage(role: .user, content: "Say OK")
            ],
            maxOutputTokens: 8,
            temperature: 0
        )
    }

    @Test(
        "a real buffered turn returns text and real usage",
        .enabled(if: LiveOpenRouterTests.isEnabled)
    )
    func liveBuffered() async throws {
        var events: [LLMStreamEvent] = []
        for try await event in try makeProvider(streaming: false).stream(request: request) {
            events.append(event)
        }

        guard case let .completed(response) = events.last else {
            Issue.record("expected .completed, got \(String(describing: events.last))")
            return
        }
        #expect(!response.text.isEmpty)
        #expect(response.providerID == .openRouter)

        let usage = try #require(await recorder.mostRecent)
        #expect(usage.promptTokens > 0, "real usage must come back non-zero")
        #expect(usage.completionTokens > 0)
        #expect(usage.reportedCostUSD != nil, "usage.include must actually yield a cost")
    }

    @Test(
        "a real SSE turn streams deltas and still captures usage",
        .enabled(if: LiveOpenRouterTests.isEnabled)
    )
    func liveStreaming() async throws {
        var deltas: [String] = []
        var completion: LLMResponse?
        for try await event in try makeProvider(streaming: true).stream(request: request) {
            switch event {
            case let .textDelta(text): deltas.append(text)
            case let .completed(response): completion = response
            case .toolCallRequested: Issue.record("unexpected tool call")
            }
        }

        let response = try #require(completion)
        #expect(!deltas.isEmpty, "a streamed turn must produce at least one delta")
        #expect(
            response.text == deltas.joined(),
            "the assembled message must equal the concatenated deltas"
        )

        let usage = try #require(await recorder.mostRecent)
        #expect(
            usage.promptTokens > 0 && usage.completionTokens > 0,
            "usage rides the chunk after finish_reason; zero here means it was dropped"
        )
    }
}
