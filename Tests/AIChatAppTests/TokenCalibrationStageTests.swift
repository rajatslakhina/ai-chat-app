import CostEstimatorKit
import Foundation
import ProviderGatewayKit
import RetryPolicyKit
import Testing
import TokenCalibrationKit
@testable import AIChatApp

/// Two fragments and a usage chunk billing `prompt` input tokens.
private func calibrationBody(prompt: Int) -> String {
    let first = #"data: {"id":"gen-cal-1","model":"openai/gpt-4o","choices":[{"delta":{"content":"Hi "},"#
        + #""finish_reason":null}]}"# + "\n\n"
    let last = #"data: {"id":"gen-cal-1","model":"openai/gpt-4o","choices":[{"delta":{"content":"there"},"#
        + #""finish_reason":"stop"}],"usage":{"prompt_tokens":"# + "\(prompt)"
        + #","completion_tokens":2,"cost":0.00001}}"# + "\n\n"
    return first + last + "data: [DONE]\n\n"
}

private func calibrationTurn(_ text: String = "How do I upload in the background?", window: Int = 128_000) -> PreparedTurn {
    PreparedTurn(
        modelID: "router/choice",
        messages: [LLMMessage(role: .system, content: "You are terse."), LLMMessage(role: .user, content: text)],
        outboundUserText: text,
        displayUserText: text,
        sources: [],
        didCompact: false,
        estimatedInputTokens: max(1, text.count / 4),
        contextWindowTokens: window
    )
}

private func calibrationExecutor(_ harness: ExecutorHarness, calibration: LiveTokenCalibration?) -> TurnExecutor {
    TurnExecutor(
        provider: OpenRouterProvider(
            configuration: OpenRouterConfiguration(apiKey: "sk-or-v1-test", streaming: true),
            session: StubURLProtocol.makeSession(),
            usageObserver: harness.usage
        ),
        idempotency: harness.idempotency,
        profiler: harness.profiler,
        estimator: CostEstimator(priceBook: ExecutorHarness.priceBook()),
        governor: harness.governor,
        retryPolicy: ExponentialBackoffRetryPolicy(maxAttempts: 1),
        meter: harness.meter,
        usage: harness.usage,
        scopes: harness.scopes,
        tokenCalibration: calibration
    )
}

private func run(_ executor: TurnExecutor, _ turn: PreparedTurn) async -> (TurnResult, PipelineTrace) {
    var trace = PipelineTrace()
    let result = await executor.execute(turn, conversationID: "calibration-1", trace: &trace, onDelta: { _ in })
    return (result, trace)
}

private func request(_ text: String, tools: [LLMToolDefinition] = []) -> LLMRequest {
    LLMRequest(messages: [LLMMessage(role: .user, content: text)], tools: tools, maxOutputTokens: 100, temperature: 0)
}

@Suite("TokenCalibrationKit - will the request fit, counted from the bills", .serialized)
struct TokenCalibrationStageTests {
    @Test("a turn that fits is sent, and its first bill teaches the wire model's calibration")
    func fitsAndLearns() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        await harness.registerPricing()
        StubURLProtocol.setStubs([StubURLProtocol.Stub(
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"],
            body: Data(calibrationBody(prompt: 31).utf8)
        )])
        let calibration = LiveTokenCalibration(wireModel: "openai/gpt-4o")

        let (result, trace) = await run(calibrationExecutor(harness, calibration: calibration), calibrationTurn())

        guard case .completed = result else {
            Issue.record("expected .completed, got \(result)")
            return
        }
        guard case let .ran(detail) = trace.outcome(for: .tokenCalibration) else {
            Issue.record("expected .ran, got \(String(describing: trace.outcome(for: .tokenCalibration)))")
            return
        }
        #expect(detail.contains("on openai/gpt-4o, prior band, 19 more bills to calibrate"))
        #expect(detail.contains("fits,"))
        #expect(detail.contains("in 128000 less 1024 for the answer"))
        // Learned under the model on the wire, not the router's choice.
        let report = try await calibration.calibrator.report(for: "openai/gpt-4o")
        #expect(report.bills == 1)
        #expect(await calibration.calibrator.calibratedModels == ["openai/gpt-4o"])
    }

    @Test("a request the model cannot take is refused before anything is held or sent")
    func refusesACertainOverflow() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        await harness.registerPricing()
        StubURLProtocol.setStubs([])
        let text = String(repeating: "東京の天気を教えてください。", count: 200)
        let calibration = LiveTokenCalibration(wireModel: "openai/gpt-4o")

        let (result, trace) = await run(
            calibrationExecutor(harness, calibration: calibration),
            calibrationTurn(text, window: 2_048)
        )

        guard case let .refused(refusal) = result else {
            Issue.record("expected .refused, got \(result)")
            return
        }
        #expect(refusal.stage == .tokenCalibration)
        #expect(refusal.headline == "Too long for this model")
        #expect(refusal.explanation.contains("would be rejected. Nothing was sent or charged."))
        #expect(refusal.recovery == .shortenConversation)
        #expect(refusal.recoveryTitle == "Start a new conversation")
        #expect(trace.outcome(for: .tokenCalibration) == .refused(refusal))
        #expect(trace.outcome(for: .budgetReserve) == nil)
        #expect(await harness.usage.recordCount == 0)
        // chars/4 would have called this 700 tokens, comfortably inside 2048 less 1024.
        #expect(text.count / 4 < 2_048 - 1_024)
    }

    @Test("without a calibrator the stage says it was skipped")
    func skippedWhenNotWired() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        await harness.registerPricing()
        StubURLProtocol.setStubs([StubURLProtocol.Stub(
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"],
            body: Data(calibrationBody(prompt: 31).utf8)
        )])

        let (_, trace) = await run(calibrationExecutor(harness, calibration: nil), calibrationTurn())

        #expect(trace.outcome(for: .tokenCalibration) == .skipped(reason: "no token calibrator is wired into this executor"))
    }

    @Test("an interval that straddles the limit is sent and says it may overflow")
    func straddlesTheLimit() async {
        let calibration = LiveTokenCalibration(wireModel: "m")
        // 400 letters: the prior puts this near 100 tokens, so 0.6x fits 130 and 1.8x does not.
        let verdict = await calibration.check(
            request(String(repeating: "a", count: 400)),
            contextWindow: 230,
            reservedOutput: 100
        )
        #expect(verdict.refusal == nil)
        guard case let .ran(detail) = verdict.outcome else {
            Issue.record("expected .ran, got \(verdict.outcome)")
            return
        }
        #expect(detail.contains("may overflow by up to"))
    }

    @Test("an estimate that cannot be made fails the stage without refusing the turn")
    func failsOpenOnAnEmptyModel() async {
        let verdict = await LiveTokenCalibration(wireModel: "").check(request("hi"), contextWindow: 1_000, reservedOutput: 10)
        #expect(verdict.refusal == nil)
        #expect(verdict.outcome == .failed(message: "\(CalibrationError.emptyModel)"))
    }

    @Test("after 19 bills the interval is calibrated from them")
    func calibratesAfterNineteenBills() async throws {
        let calibration = LiveTokenCalibration(wireModel: "m")
        for index in 0..<19 {
            let text = String(repeating: "word ", count: 20 + index)
            #expect(await calibration.learn(request(text), billed: 30 + index) != nil)
        }
        let verdict = await calibration.check(request("one more question"), contextWindow: 10_000, reservedOutput: 100)
        guard case let .ran(detail) = verdict.outcome else {
            Issue.record("expected .ran, got \(verdict.outcome)")
            return
        }
        #expect(detail.contains("calibrated on 19 bills at 90%"))
        #expect(!detail.contains("never billed for"))

        // Digits were in none of those bills, so that part of the estimate keeps the prior band.
        let digits = await calibration.check(request("one more question 1234567890"), contextWindow: 10_000, reservedOutput: 100)
        guard case let .ran(withDigits) = digits.outcome else {
            Issue.record("expected .ran, got \(digits.outcome)")
            return
        }
        #expect(withDigits.contains("(5 of them from text this model was never billed for, bounded by the prior band)"))
    }

    @Test("a request's features include its tool definitions and framing")
    func featuresCountTools() {
        let tool = LLMToolDefinition(name: "calculator", toolDescription: "Adds numbers", parameterSchema: [:])
        let features = LiveTokenCalibration.features(of: request("2 + 2", tools: [tool]))
        #expect(features.messages == 1)
        #expect(features.tools == 1)
        #expect(features.requests == 1)
        #expect(features.count(of: .digit) == 2)
    }

    @Test("a turn with no billed first call teaches nothing")
    func noFirstCallNoLesson() async throws {
        let harness = ExecutorHarness()
        let calibration = LiveTokenCalibration(wireModel: "openai/gpt-4o")
        let executor = calibrationExecutor(harness, calibration: calibration)
        #expect(await executor.learnTokenRates(calibrationTurn(), firstCall: nil) == nil)
        #expect(await calibrationExecutor(harness, calibration: nil).learnTokenRates(
            calibrationTurn(),
            firstCall: OpenRouterUsage(
                requestID: nil, model: "openai/gpt-4o", promptTokens: 10, completionTokens: 1,
                cachedPromptTokens: 0, reportedCostUSD: nil
            )
        ) == nil)
        #expect(await calibration.calibrator.calibratedModels.isEmpty)
    }
}
