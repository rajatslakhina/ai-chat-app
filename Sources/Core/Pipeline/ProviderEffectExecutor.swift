import AgentLoopKit
import Foundation
import IdempotencyKit
import ProviderGatewayKit
import RetryPolicyKit
import ToolRegistryKit

/// Performs the actual provider call, under the retry policy, inside the idempotency guard — and,
/// when the model asks for one, the tool round trip that turns its request into prose.
///
/// A separate type from `TurnExecutor` because `IdempotencyGuard.execute` takes an
/// `EffectExecuting`, and that is the right shape: the guard decides *whether* the effect happens,
/// this decides *how*. The whole round trip lives inside one effect on purpose — a turn that
/// called a tool and then answered is one billable unit of work as far as a double-tapped Send is
/// concerned, and splitting it would let a replay re-run the tool.
actor ProviderEffectExecutor: EffectExecuting {
    private let provider: OpenRouterProvider
    private let request: LLMRequest
    private let retryPolicy: ExponentialBackoffRetryPolicy
    private let onDelta: @Sendable (String) -> Void
    private let tools: ToolRoundTrip?
    private let context: ToolCallContext
    private let onToolActivity: @Sendable (ToolActivity) -> Void
    private let maxToolHops: Int

    private var attempts = 0
    private var deltas = 0
    private var lastProviderError: ProviderError?
    private var toolStages: [StageRecord] = []

    init(
        provider: OpenRouterProvider,
        request: LLMRequest,
        retryPolicy: ExponentialBackoffRetryPolicy,
        onDelta: @escaping @Sendable (String) -> Void,
        tools: ToolRoundTrip? = nil,
        context: ToolCallContext = ToolCallContext(
            conversationID: "unscoped",
            provenance: .modelAuthored
        ),
        onToolActivity: @escaping @Sendable (ToolActivity) -> Void = { _ in },
        maxToolHops: Int = 3
    ) {
        self.provider = provider
        self.request = request
        self.retryPolicy = retryPolicy
        self.onDelta = onDelta
        self.tools = tools
        self.context = context
        self.onToolActivity = onToolActivity
        self.maxToolHops = max(1, maxToolHops)
    }

    func attemptsMade() -> Int { attempts }
    func deltaCount() -> Int { deltas }

    /// What the tool stages did, for the caller to fold into the `PipelineTrace`. Empty when the
    /// effect never ran, which is exactly what a replayed turn looks like.
    func toolRecords() -> [StageRecord] { toolStages }

    /// The provider error behind a failure, kept because `IdempotencyGuard.execute` replaces
    /// whatever the executor threw with an `EffectFailure` of its own. Without this the caller
    /// cannot tell a rate limit from a dead socket, and every failure becomes the same banner.
    func providerFailure() -> ProviderError? { lastProviderError }

    func perform(_ payload: EffectPayload) async throws -> EffectResult {
        try await run()
    }

    private func run() async throws -> EffectResult {
        while true {
            attempts += 1
            do {
                let body = try await runTurn()
                return EffectResult(body: body, metadata: ["attempts": "\(attempts)"])
            } catch {
                let hint = Self.retryHint(for: error)
                switch retryPolicy.decision(forAttempt: attempts, retryAfterHint: hint) {
                case let .retry(after):
                    // The provider said "slow down"; honour it rather than hammering.
                    try? await Task.sleep(nanoseconds: UInt64(max(0, after) * 1_000_000_000))
                case .giveUp:
                    // Classify before rethrowing. `IdempotencyGuard` freezes the key on an
                    // unclassified error, on the reasoning that the effect *might* have applied.
                    // For these it provably did not — a 429, a rejected key or a timeout before
                    // any bytes were accepted means nothing was charged — so the key must stay
                    // free or the user could never retry this exact message again.
                    if let providerError = error as? ProviderError {
                        lastProviderError = providerError
                        throw EffectFailure(
                            reason: "\(providerError)",
                            mode: Self.failureMode(for: providerError)
                        )
                    }
                    throw error
                }
            }
        }
    }

    /// Whether the effect provably did not happen.
    ///
    /// Everything the provider rejects before streaming a byte is `.notApplied`: no tokens were
    /// billed, so the key is safe to reuse. A connection that dropped mid-stream is the genuinely
    /// ambiguous case — the upstream may have completed and charged for it — so that one stays
    /// `.indeterminate` and the guard freezes the key, which is the behaviour it exists for.
    static func failureMode(for error: ProviderError) -> FailureMode {
        switch error {
        case .rateLimited, .capabilityMismatch:
            return .notApplied
        case .timeout, .connectionFailed:
            return .indeterminate
        }
    }

    /// Only a rate limit carries a server-supplied delay. Everything else backs off on the
    /// policy's own schedule.
    static func retryHint(for error: Error) -> TimeInterval? {
        guard case let .rateLimited(retryAfter)? = error as? ProviderError,
              let retryAfter else { return nil }
        return TimeInterval(retryAfter.components.seconds)
    }
}

// MARK: - The tool round trip

extension ProviderEffectExecutor {
    /// What one hop of the conversation with the model produced.
    private enum HopOutcome {
        case text(String, raw: String)
        case toolCall(ProviderGatewayKit.ToolCallRequest, raw: String)
    }

    /// Everything one whole turn accumulates across its hops.
    private struct TurnState {
        var messages: [LLMMessage]
        var prompt: String
        var assembled = ""
        var steps: [AgentStep] = []
        var hops = 0
    }

    /// One whole turn: the first model call, any tool call it asks for, and the further call that
    /// turns the tool's result back into prose the user can read.
    private func runTurn() async throws -> String {
        toolStages = []
        var state = TurnState(
            messages: request.messages,
            prompt: request.messages.last?.content ?? ""
        )
        while true {
            switch try await streamOnce(messages: state.messages, into: &state.assembled) {
            case let .text(text, raw):
                if state.assembled.isEmpty { state.assembled = text }
                let answer = state.assembled
                finish(&state, answer: answer, raw: raw)
                return answer
            case let .toolCall(call, raw):
                guard state.hops < maxToolHops else {
                    recordCap(&state)
                    return state.assembled
                }
                state.hops += 1
                guard let observation = await applyHop(call, raw: raw, to: &state) else {
                    recordStoppedEarly(&state)
                    return state.assembled
                }
                state.prompt = observation
                state.messages.append(LLMMessage(role: .user, content: observation))
            }
        }
    }

    /// Streams one model call, folding its text into `assembled` as it arrives.
    private func streamOnce(
        messages: [LLMMessage],
        into assembled: inout String
    ) async throws -> HopOutcome {
        let hop = LLMRequest(
            messages: messages,
            tools: request.tools,
            maxOutputTokens: request.maxOutputTokens,
            temperature: request.temperature
        )
        var raw = ""
        for try await event in provider.stream(request: hop) {
            switch event {
            case let .textDelta(fragment):
                deltas += 1
                raw += fragment
                assembled += fragment
                onDelta(fragment)
            case let .completed(response):
                return .text(response.text.isEmpty ? raw : response.text, raw: raw)
            case let .toolCallRequested(call):
                return .toolCall(call, raw: raw)
            }
        }
        return .text(raw, raw: raw)
    }

    /// Authorizes and dispatches one requested call. Returns the observation to send back, or nil
    /// when nothing ran and the turn must stop where it is.
    private func applyHop(
        _ call: ProviderGatewayKit.ToolCallRequest,
        raw: String,
        to state: inout TurnState
    ) async -> String? {
        let argumentsJSON = Self.argumentsJSON(call.arguments)
        guard let tools else {
            toolStages.append(contentsOf: Self.unwiredRecords(for: call.toolName))
            return nil
        }
        onToolActivity(.started(tool: call.toolName))
        let resolution = await tools.resolve(
            id: call.id,
            toolName: call.toolName,
            argumentsJSON: argumentsJSON,
            in: context
        )
        toolStages.append(contentsOf: resolution.records)
        onToolActivity(resolution.activity)
        state.steps.append(
            AgentStep(
                index: state.steps.count,
                prompt: state.prompt,
                rawResponseText: raw,
                decision: .toolCall(
                    ToolRegistryKit.ToolCallRequest(
                        id: call.id,
                        toolName: call.toolName,
                        argumentsJSON: argumentsJSON
                    )
                ),
                toolResult: resolution.result
            )
        )
        return resolution.observation
    }

    /// Re-encodes the gateway's parsed arguments as the raw JSON bytes `ToolRegistryKit` wants.
    ///
    /// `ToolRegistryKit.ToolCallRequest` takes `argumentsJSON: Data`; ProviderGatewayKit's
    /// same-named type takes a parsed dictionary. The two are different types with the same name
    /// from two linked packages, which is why every mention of either is qualified.
    static func argumentsJSON(_ arguments: [String: LLMToolArgumentValue]) -> Data {
        let json = OpenRouterJSON.object(arguments.mapValues(OpenRouterJSON.init))
        return (try? JSONEncoder().encode(json)) ?? Data("{}".utf8)
    }

    static func unwiredRecords(for toolName: String) -> [StageRecord] {
        let reason = "\(toolName) was requested but no tool registry is configured"
        return [
            StageRecord(stage: .toolAuthority, outcome: .skipped(reason: reason), durationMs: 0),
            StageRecord(stage: .toolDispatch, outcome: .skipped(reason: reason), durationMs: 0)
        ]
    }
}

// MARK: - What the agent loop did

extension ProviderEffectExecutor {
    private func finish(_ state: inout TurnState, answer: String, raw: String) {
        state.steps.append(
            AgentStep(
                index: state.steps.count,
                prompt: state.prompt,
                rawResponseText: raw,
                decision: .finalAnswer(answer),
                toolResult: nil
            )
        )
        let settled = answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        record(
            AgentTranscript(
                steps: state.steps,
                finalAnswer: settled ? nil : answer,
                haltReason: settled ? .parseFailed(.emptyResponse) : .finalAnswer
            )
        )
    }

    private func recordCap(_ state: inout TurnState) {
        record(
            AgentTranscript(
                steps: state.steps,
                finalAnswer: nil,
                haltReason: .maxStepsExceeded
            )
        )
    }

    /// The gate declined, or no registry was configured. Neither is a halt reason AgentLoopKit
    /// models — nothing was dispatched and the loop did not run out of steps — so this is recorded
    /// as the loop correctly doing nothing further rather than forced into a case that would read
    /// as a tool failure in Diagnostics.
    private func recordStoppedEarly(_ state: inout TurnState) {
        toolStages.append(
            StageRecord(
                stage: .agentLoop,
                outcome: .noOp(
                    reason: "stopped after \(state.hops) hop(s); no further model call was made"
                ),
                durationMs: 0
            )
        )
    }

    private func record(_ transcript: AgentTranscript) {
        // A turn where the model asked for nothing still has to report the two stages it did not
        // need. `PipelineTrace.unreached` is how this app makes a silently dead package visible,
        // and an unrecorded stage is indistinguishable from one that was never wired at all.
        if !toolStages.contains(where: { $0.stage == .toolAuthority }) {
            toolStages.append(
                contentsOf: Self.untouchedRecords(toolsAvailable: !request.tools.isEmpty)
            )
        }
        toolStages.append(
            StageRecord(
                stage: .agentLoop,
                outcome: agentLoopOutcome(for: transcript),
                durationMs: 0
            )
        )
    }

    private func agentLoopOutcome(for transcript: AgentTranscript) -> StageOutcome {
        guard !request.tools.isEmpty else {
            return .skipped(reason: "no tools registered for this conversation")
        }
        let called = Self.toolNames(in: transcript)
        switch transcript.haltReason {
        case .finalAnswer where called.isEmpty:
            // Not an absence: the loop ran and correctly did nothing, which is the distinction
            // `.noOp` exists to preserve against a stage that never reported at all.
            return .noOp(reason: "model answered directly; no tool call requested")
        case .finalAnswer:
            return .ran(
                detail: "\(called.count) tool call(s) over \(transcript.steps.count) step(s): "
                    + called.joined(separator: ", ")
            )
        case .maxStepsExceeded:
            return .refused(
                Refusal(
                    stage: .agentLoop,
                    headline: "Stopped after \(maxToolHops) tool calls",
                    explanation: "The assistant kept looking things up without answering.",
                    recovery: .switchModel
                )
            )
        case let .parseFailed(error):
            // The provider broke rather than the system declining, so this is a failure.
            return .failed(message: error.description)
        case let .toolDispatchFailed(error):
            return .failed(message: error.description)
        }
    }

    static func toolNames(in transcript: AgentTranscript) -> [String] {
        transcript.steps.compactMap { step in
            guard case let .toolCall(request)? = step.decision else { return nil }
            return request.toolName
        }
    }

    /// Records the three tool stages for a turn that never reached the network, so a replayed send
    /// reads as "not repeated" rather than as three silently unwired packages.
    static func replayedRecords() -> [StageRecord] {
        let reason = "replayed an earlier result; the tool round trip was not repeated"
        return [PipelineStage.toolAuthority, .toolDispatch, .agentLoop].map {
            StageRecord(stage: $0, outcome: .skipped(reason: reason), durationMs: 0)
        }
    }

    /// Records the two dispatch-side stages for a turn where no tool call was made.
    ///
    /// `.noOp` when tools were offered and the model chose not to use one — the common path for
    /// ordinary chat. `.skipped` when there was nothing to offer, which is a different fact.
    static func untouchedRecords(toolsAvailable: Bool) -> [StageRecord] {
        let outcome: StageOutcome = toolsAvailable
            ? .noOp(reason: "model requested no tools")
            : .skipped(reason: "no tools registered for this conversation")
        return [PipelineStage.toolAuthority, PipelineStage.toolDispatch].map {
            StageRecord(stage: $0, outcome: outcome, durationMs: 0)
        }
    }
}
