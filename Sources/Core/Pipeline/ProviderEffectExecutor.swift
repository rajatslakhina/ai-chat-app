import AgentLoopKit
import AnswerContinuationKit
import DegenerationGuardKit
import Foundation
import IdempotencyKit
import LoopGuardKit
import ProviderGatewayKit
import RetryPolicyKit
import StreamReleaseKit
import ToolRegistryKit
import VerifiedCallKit

/// Performs the actual provider call, under the retry policy, inside the idempotency guard — and,
/// when the model asks for one, the tool round trip that turns its request into prose.
///
/// A separate type from `TurnExecutor` because `IdempotencyGuard.execute` takes an
/// `EffectExecuting`, and that is the right shape: the guard decides *whether* the effect happens,
/// this decides *how*. The whole round trip lives inside one effect on purpose — a turn that
/// called a tool and then answered is one billable unit of work as far as a double-tapped Send is
/// concerned, and splitting it would let a replay re-run the tool.
actor ProviderEffectExecutor: EffectExecuting {
    let provider: OpenRouterProvider
    let request: LLMRequest
    private let retryPolicy: ExponentialBackoffRetryPolicy
    private let onDelta: @Sendable (String) -> Void
    private let tools: ToolRoundTrip?
    private let context: ToolCallContext
    private let onToolActivity: @Sendable (ToolActivity) -> Void
    private let maxToolHops: Int
    /// Nil streams fragments straight through, as callers that never asked for a gate expect.
    private let releaseScanners: [any StreamScanner]?

    private var attempts = 0
    /// A fresh gate per attempt: text a failed attempt was still holding back is never shown.
    private var releaseGate: ReleaseGate?
    private var releaseStats: ReleaseStats?
    /// One loop monitor per model call; this is what they saw during the current attempt.
    private var degeneration = LiveDegenerationGuard.Summary()
    /// How the final model call of the current attempt stopped, and what continuing it did.
    var continuation = LiveAnswerContinuation.Record.none
    private var deltas = 0
    private var lastProviderError: ProviderError?
    private var toolStages: [StageRecord] = []
    /// What each successful tool call returned this attempt, for `numberBinding` to bind figures to.
    private(set) var toolOutputs: [ToolOutput] = []
    /// Asks, before each resend, whether the failed attempt had already been billed.
    private let verifier = InDoubtVerification.caller()
    private var verification = InDoubtVerification.Summary()
    /// What the current attempt received: fragments and tool-call hops, and the text so far.
    private var attemptEvidence = 0
    private var attemptText = ""
    private var lastAttemptError: (any Error)?

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
        maxToolHops: Int = 3,
        releaseScanners: [any StreamScanner]? = nil
    ) {
        self.releaseScanners = releaseScanners
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

    /// What the live-stream gate did on the attempt that succeeded. Nil when no gate ran.
    func liveReleaseStats() -> ReleaseStats? { releaseStats }
    func degenerationSummary() -> LiveDegenerationGuard.Summary { degeneration }
    func continuationRecord() -> LiveAnswerContinuation.Record { continuation }

    /// What the tool stages did, for the caller to fold into the `PipelineTrace`. Empty when the
    /// effect never ran, which is exactly what a replayed turn looks like.
    func toolRecords() -> [StageRecord] { toolStages }

    /// The provider error behind a failure, kept because `IdempotencyGuard.execute` replaces
    /// whatever the executor threw with an `EffectFailure` of its own. Without this the caller
    /// cannot tell a rate limit from a dead socket, and every failure becomes the same banner.
    func providerFailure() -> ProviderError? { lastProviderError }

    /// What the in-doubt check saw across this turn's attempts.
    func verificationSummary() -> InDoubtVerification.Summary { verification }

    func perform(_ payload: EffectPayload) async throws -> EffectResult {
        try await run()
    }

    private func run() async throws -> EffectResult {
        while true {
            attempts += 1
            let outcome = await verifier.execute(attemptEffect())
            if case .succeeded(let body) = outcome.resolution {
                await flushRelease()
                return EffectResult(body: body, metadata: ["attempts": "\(attempts)"])
            }
            let error = lastAttemptError ?? CancellationError()
            if case .recovered = outcome.resolution {
                // Part of the answer had arrived, so this attempt was billed. Resending it would pay
                // for the answer twice without asking; the user decides instead.
                verification.stop = InDoubtVerification.Stop(
                    attempt: attempts,
                    evidence: attemptEvidence,
                    cause: "\(error)"
                )
                throw EffectFailure(
                    reason: "attempt \(attempts) was billed and lost its answer: \(error)",
                    mode: .indeterminate
                )
            }
            verification.absorb(outcome.attempts.last?.verdict)
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

    /// One attempt as `VerifiedCaller` sees it: the whole turn, and a probe that reads what the
    /// attempt received. Fragments or a tool-call hop mean OpenRouter did the work and billed it.
    /// Nothing received means nothing to look up, so the probe says it cannot answer rather than
    /// claiming the attempt did nothing.
    private func attemptEffect() -> ClosureEffect<String> {
        ClosureEffect(
            key: "attempt-\(attempts)",
            perform: { _ in try await self.attemptTurn() },
            probe: { _ in try await self.attemptReading() }
        )
    }

    private func attemptTurn() async throws -> String {
        attemptEvidence = 0
        attemptText = ""
        lastAttemptError = nil
        do {
            return try await runTurn()
        } catch {
            lastAttemptError = error
            throw error
        }
    }

    private func attemptReading() throws -> ProbeReading<String> {
        guard attemptEvidence > 0 else { throw InDoubtVerification.NoLookup() }
        return .applied(attemptText)
    }
}

// MARK: - The tool round trip

extension ProviderEffectExecutor {
    /// What one hop of the conversation with the model produced.
    private enum HopOutcome {
        case text(String, raw: String, stop: LLMResponse.FinishReason?)
        case toolCall(ProviderGatewayKit.ToolCallRequest, raw: String)
    }

    /// Everything one whole turn accumulates across its hops.
    private struct TurnState {
        var messages: [LLMMessage]
        var prompt: String
        var assembled = ""
        var steps: [AgentStep] = []
        var hops = 0
        let loopGuard = LoopGuard(policy: ToolLoopWatch.policy)
        var loopWatch = ToolLoopWatch.Summary()
        var progress = ToolProgressCheck.Ledger()
    }

    /// One whole turn: the first model call, any tool call it asks for, and the further call that
    /// turns the tool's result back into prose the user can read.
    private func runTurn() async throws -> String {
        toolStages = []
        toolOutputs = []
        releaseGate = releaseScanners.map { ReleaseGate(scanners: $0) }
        degeneration = LiveDegenerationGuard.Summary()
        continuation = .none
        var state = TurnState(
            messages: request.messages,
            prompt: request.messages.last?.content ?? ""
        )
        while true {
            switch try await streamOnce(messages: state.messages, into: &state.assembled) {
            case let .text(text, raw, stop):
                if state.assembled.isEmpty { state.assembled = text }
                let answer = await finishIfCut(state.assembled, stop: stop, messages: state.messages)
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
                if let signal = state.loopWatch.halted {
                    recordLoopHalt(&state, signal: signal)
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
        let before = assembled
        var monitor = DegenerationMonitor(policy: LiveDegenerationGuard.policy)
        defer { degeneration.absorb(monitor) }
        for try await event in provider.stream(request: hop) {
            switch event {
            case let .textDelta(fragment):
                deltas += 1
                attemptEvidence += 1
                attemptText += fragment
                raw += fragment
                assembled += fragment
                await emit(fragment)
                // Leaving the loop ends the iteration, and the provider's `onTermination` cancels
                // the request: the rest of the loop is never generated.
                if let finding = monitor.ingest(fragment).finding {
                    let kept = DegenerationGuard.salvage(raw, keeping: finding).text
                    assembled = before + kept
                    return .text(kept, raw: raw, stop: nil)
                }
            case let .completed(response):
                let text = response.text.isEmpty ? raw : response.text
                return .text(text, raw: raw, stop: response.finishReason)
            case let .toolCallRequested(call):
                attemptEvidence += 1
                return .toolCall(call, raw: raw)
            }
        }
        return .text(raw, raw: raw, stop: nil)
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
        if let output = resolution.result.flatMap(ToolOutput.init) { toolOutputs.append(output) }
        state.progress.absorb(
            tool: call.toolName,
            dispatched: resolution.result != nil,
            keptContract: resolution.keptContract
        )
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
        guard let observation = resolution.observation else { return nil }
        let verdict = await state.loopGuard.record(
            ToolLoopWatch.step(
                toolName: call.toolName,
                argumentsJSON: argumentsJSON,
                observation: observation
            )
        )
        state.loopWatch.absorb(verdict)
        return ToolLoopWatch.observation(resolution.framedObservation ?? observation, after: verdict)
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
        recordLoopWatch(state.loopWatch)
        let toolsAvailable = !request.tools.isEmpty
        recordProgress(
            settled
                ? ToolProgressCheck.unanswered(toolsAvailable: toolsAvailable)
                : ToolProgressCheck.outcome(answeredWith: state.progress, toolsAvailable: toolsAvailable)
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
        recordLoopWatch(state.loopWatch)
        recordUnanswered()
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
        recordLoopWatch(state.loopWatch)
        recordUnanswered()
    }

    /// The loop guard stopped the turn. AgentLoopKit has no halt reason for it (the loop did not
    /// run out of steps, and nothing failed), so the agent loop reads as correctly doing nothing
    /// further and the loop guard's own `.refused` record carries the banner.
    private func recordLoopHalt(_ state: inout TurnState, signal: LoopSignal) {
        toolStages.append(
            StageRecord(
                stage: .agentLoop,
                outcome: .noOp(
                    reason: "stopped by the loop guard after \(state.hops) hop(s): \(signal.summary)"
                ),
                durationMs: 0
            )
        )
        recordLoopWatch(state.loopWatch)
        recordUnanswered()
    }

    private func recordLoopWatch(_ summary: ToolLoopWatch.Summary) {
        toolStages.append(
            StageRecord(
                stage: .loopGuard,
                outcome: ToolLoopWatch.outcome(for: summary, toolsAvailable: !request.tools.isEmpty),
                durationMs: 0
            )
        )
    }

    private func recordUnanswered() {
        recordProgress(ToolProgressCheck.unanswered(toolsAvailable: !request.tools.isEmpty))
    }

    private func recordProgress(_ outcome: StageOutcome) {
        toolStages.append(StageRecord(stage: .progressGate, outcome: outcome, durationMs: 0))
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
                outcome: Self.agentLoopOutcome(
                    for: transcript, hasTools: !request.tools.isEmpty, maxToolHops: maxToolHops
                ),
                durationMs: 0
            )
        )
    }
}

// MARK: - The live-stream gate

extension ProviderEffectExecutor {
    /// Hands a fragment to the UI, through the gate when there is one.
    private func emit(_ fragment: String) async {
        guard let releaseGate else {
            onDelta(fragment)
            return
        }
        let release = await releaseGate.ingest(fragment)
        if !release.text.isEmpty { onDelta(release.text) }
    }

    /// Releases what the gate still holds once the turn has finished, and keeps its numbers.
    private func flushRelease() async {
        guard let releaseGate else { return }
        let rest = await releaseGate.finish()
        if !rest.text.isEmpty { onDelta(rest.text) }
        releaseStats = await releaseGate.stats
    }
}
