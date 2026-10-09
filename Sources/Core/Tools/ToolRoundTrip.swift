import AgentLoopKit
import ContentBoundaryKit
import Foundation
import OutcomeMonitorKit
import ProviderGatewayKit
import StructuredOutputKit
import ToolAuthorityKit
import ToolRegistryKit

/// What the chat UI should show while a tool is in flight, and afterwards.
enum ToolActivity: Sendable, Equatable {
    case started(tool: String)
    /// The tool ran and returned. The chip settles to "Used <tool>".
    case finished(tool: String)
    /// Nothing ran and nothing should be shown — either the authority gate declined, in which case
    /// the refusal banner speaks for it, or the model named a tool that does not exist and will
    /// name a real one on the next hop.
    case cleared(tool: String)
    /// The tool's own handler threw. This is the one the user has to see.
    case failed(tool: String, message: String)
}

/// Where a tool call's arguments came from, which the packages cannot infer for themselves.
struct ToolCallContext: Sendable, Equatable {
    let conversationID: String
    let provenance: Provenance
    /// The passages this turn actually retrieved, carried so the selection-trust stage can ask
    /// whether an argument's bytes appear in one. `provenance` above collapses that question into
    /// a single stamp; keeping the passages is what lets the two be separated.
    var sources: [RetrievedSource] = []

    /// Arguments the model composed are `.modelAuthored`; arguments composed after retrieval
    /// injected passages are `.untrusted`, named for the passage that ranked highest. That is the
    /// distinction the whole authority layer turns on, and only this app can make it.
    static func forTurn(conversationID: String, sources: [RetrievedSource]) -> ToolCallContext {
        guard let first = sources.first else {
            return ToolCallContext(conversationID: conversationID, provenance: .modelAuthored, sources: [])
        }
        return ToolCallContext(
            conversationID: conversationID,
            provenance: .untrusted(source: first.id),
            sources: sources
        )
    }
}

/// What one tool call the model asked for turned into.
struct ToolCallResolution: Sendable {
    /// No default. Every path through `resolve` records at least the authority stage, and a
    /// default of `[]` would let a future one silently report nothing — which is the difference
    /// between a stage that did nothing and a stage that was never wired in.
    var records: [StageRecord]
    /// The text fed back to the model so it can answer in prose. Nil when the call did not run and
    /// there is nothing truthful to feed back.
    var observation: String?
    /// A refusal that must reach the user. The model's own prose still publishes underneath it.
    var refusal: Refusal?
    var activity: ToolActivity
    var result: ToolCallResult?
    /// Whether the result kept its outcome contract; nil when there was no result to check. Read by
    /// the completion check when the model later answers.
    var keptContract: Bool?
    /// `observation` as the model reads it: the tool's payload inside a ContentBoundaryKit envelope.
    /// Kept apart from `observation` because the loop guard compares results across hops, and a
    /// fresh envelope id on every hop would make two identical results look different.
    var framedObservation: String?
}

/// Authorizes a tool call and then dispatches it.
///
/// The order is the point: `ToolAuthorityKit` is asked before `ToolRegistryKit` runs anything,
/// never after. A registry that has already executed a handler cannot be un-executed by a policy
/// decision, so a gate placed on the other side of dispatch is decoration.
actor ToolRoundTrip {
    private let registry: ToolRegistryKit.ToolRegistry
    private let gate: ToolAuthorityGate
    private let strategy: any AgentPromptStrategy
    private let outcomes: OutcomeMonitor
    private let nonces: @Sendable () -> any NonceSource
    /// One boundary session per conversation, so an envelope id the model leaks in one hop is
    /// recognised when a later tool result quotes it back.
    private var boundaries: [String: BoundarySession] = [:]

    /// `DefaultAgentPromptStrategy` formats every observation, success and failure alike. Using
    /// AgentLoopKit's own strategy rather than a hand-rolled string means the error path is worded
    /// the same way as the success path — `{"error": "…"}` — which is what lets a model treat a
    /// tool mistake as something to correct rather than as a change of subject.
    init(
        registry: ToolRegistryKit.ToolRegistry,
        gate: ToolAuthorityGate,
        strategy: any AgentPromptStrategy = DefaultAgentPromptStrategy(),
        outcomes: OutcomeMonitor = ToolOutcomeCheck.monitor(),
        nonces: @escaping @Sendable () -> any NonceSource = { SystemNonceSource() }
    ) {
        self.registry = registry
        self.gate = gate
        self.strategy = strategy
        self.outcomes = outcomes
        self.nonces = nonces
    }

    /// The `tools` array sent to OpenRouter, in the registry's own stable order.
    ///
    /// `registeredDefinitions` sorts by name, so the outbound bytes do not change between sends —
    /// worth keeping, because OpenRouter's prompt caching keys on exact bytes.
    func wireTools() async -> [LLMToolDefinition] {
        await registry.registeredDefinitions.map(ToolSchemaBridge.wireDefinition)
    }

    /// Cumulative for the life of the registry actor, with no reset — a per-conversation figure
    /// would need two snapshots diffed by the caller.
    func statistics() async -> ToolDispatchStatistics {
        await registry.statisticsSnapshot
    }

    func closeConversation(_ conversationID: String) async {
        boundaries[conversationID] = nil
        await gate.close(conversationID: conversationID)
    }

    private func boundary(for conversationID: String) -> BoundarySession {
        if let existing = boundaries[conversationID] { return existing }
        let session = BoundarySession(policy: ToolResultBoundary.policy, nonceSource: nonces())
        boundaries[conversationID] = session
        return session
    }

    // MARK: - Approval

    /// Whether a tool call needs a human signature before it runs. Written by Settings.
    func setApprovalRequired(_ required: Bool) async {
        await gate.setRequiresApproval(required)
    }

    /// The call waiting on a human, if one is. Read by the chat screen when the user taps the
    /// refusal banner's "Approve <tool>" button.
    func pendingApproval() async -> ToolApprovalPrompt? {
        await gate.pendingApproval()
    }

    /// Signs the pending call. False when nothing was pending, so the caller does not resend into
    /// the same refusal.
    func approvePending(approver: String) async -> Bool {
        await gate.approvePending(approver: approver)
    }

    func declinePending() async {
        await gate.declinePending()
    }

    /// Folded into the turn's idempotency key so a resend after an approval is a new operation
    /// rather than a replay of the send the approval was meant to unblock.
    func approvalGeneration() async -> Int {
        await gate.approvalGeneration
    }

    func resolve(
        id: String,
        toolName: String,
        argumentsJSON: Data,
        in context: ToolCallContext
    ) async -> ToolCallResolution {
        let known = await registry.registeredDefinitions.contains { $0.name == toolName }
        // Canonical before authority: the digest a signature binds to, and the bytes that run,
        // are the call's values rather than this run's spelling of them.
        let (canonical, consistency) = await ToolCallReplay.prepare(
            argumentsJSON, tool: toolName, conversationID: context.conversationID, gate: gate
        )
        let authority = await authorize(
            toolName: toolName, arguments: canonical.text, known: known, in: context
        )
        let selection = await SelectionTrustGate.record(
            for: SelectionTrustGate.read(
                toolName: toolName,
                argumentsJSON: argumentsJSON,
                sources: context.sources
            ),
            toolName: toolName
        )
        let attribution = await ArgumentAttributionGate.record(
            for: ArgumentAttributionGate.read(
                toolName: toolName,
                argumentsJSON: argumentsJSON,
                sources: context.sources
            ),
            toolName: toolName
        )
        guard authority.proceed else {
            return ToolCallResolution(
                records: [
                    consistency,
                    authority.record,
                    selection,
                    attribution,
                    Self.record(.toolDispatch, .skipped(reason: "the call was not authorized")),
                    ToolOutcomeCheck.skipped("the call was not authorized, so nothing returned"),
                    ToolResultBoundary.skipped("the call was not authorized, so there is no result to frame")
                ] + StructuralToolSkips.records,
                observation: nil,
                refusal: authority.refusal,
                activity: .cleared(tool: toolName)
            )
        }
        var resolution = await dispatch(
            id: id,
            toolName: toolName,
            argumentsJSON: canonical.arguments,
            conversationID: context.conversationID
        )
        resolution.records.insert(contentsOf: [consistency, authority.record, selection, attribution], at: 0)
        resolution.records.append(contentsOf: StructuralToolSkips.records)
        return resolution
    }

    private struct AuthorityStep {
        let record: StageRecord
        var refusal: Refusal?
        var proceed: Bool
    }

    private func authorize(
        toolName: String,
        arguments: String,
        known: Bool,
        in context: ToolCallContext
    ) async -> AuthorityStep {
        guard known else {
            // A name that names nothing cannot be dispatched, so there is no authority question to
            // ask about it. The registry's own `.unknownTool` is the right answer and it goes back
            // to the model, which usually names a real tool on the next hop. Denying it here would
            // show the user a banner for a mistake the model corrects by itself.
            return AuthorityStep(
                record: Self.record(
                    .toolAuthority,
                    .noOp(reason: "\(toolName) is not a registered tool; nothing to authorize")
                ),
                refusal: nil,
                proceed: true
            )
        }
        let verdict = await gate.decide(
            tool: toolName,
            arguments: arguments,
            conversationID: context.conversationID,
            provenance: context.provenance
        )
        return Self.step(for: verdict, toolName: toolName)
    }

    private static func step(
        for verdict: ToolAuthorityVerdict,
        toolName: String
    ) -> AuthorityStep {
        switch verdict {
        case let .allowed(detail):
            return AuthorityStep(record: record(.toolAuthority, .ran(detail: detail)), proceed: true)
        case let .denied(refusal):
            return AuthorityStep(
                record: record(.toolAuthority, .refused(refusal)),
                refusal: refusal,
                proceed: false
            )
        case let .approvalRequired(refusal):
            // `.refused`, and the distinction is not academic: `PipelineTrace.refusal` finds the
            // turn's refusal by scanning for a `.refused` record, and `applyHop` forwards only
            // `resolution.records` — it drops `resolution.refusal` on the floor. Recording this as
            // `.ran` (which read well: nothing was refused, the turn is waiting on a human) meant
            // the banner never appeared, so the turn stopped in silence with no way to approve.
            // Unreachable until a capability actually set `requiresApproval`, which is why it
            // survived: the denied path carries its own `.refused` record and looked identical.
            return AuthorityStep(
                record: record(.toolAuthority, .refused(refusal)),
                refusal: refusal,
                proceed: false
            )
        case let .failed(message):
            // Authority could not be established, so nothing may run. A failure is not a refusal
            // and must not be dressed as one, but it stops the call just as firmly.
            return AuthorityStep(
                record: record(.toolAuthority, .failed(message: message)),
                proceed: false
            )
        }
    }

    private func dispatch(
        id: String,
        toolName: String,
        argumentsJSON: Data,
        conversationID: String
    ) async -> ToolCallResolution {
        guard !Task.isCancelled else {
            // `dispatch` catches `CancellationError` with the same `catch` as any other error and
            // reports it as `.handlerThrew`, which shows the user a failure that did not happen
            // and permanently skews `statisticsSnapshot` — a struct with no reset.
            return ToolCallResolution(
                records: [
                    Self.record(.toolDispatch, .skipped(reason: "the turn was cancelled")),
                    ToolOutcomeCheck.skipped("the turn was cancelled before the call ran"),
                    ToolResultBoundary.skipped("the turn was cancelled before the call ran")
                ],
                observation: nil,
                refusal: nil,
                activity: .cleared(tool: toolName)
            )
        }
        let started = DispatchTime.now()
        let result = await registry.dispatch(
            ToolRegistryKit.ToolCallRequest(
                id: id,
                toolName: toolName,
                argumentsJSON: Self.normalized(argumentsJSON)
            )
        )
        let elapsed = DispatchTime.now().uptimeNanoseconds &- started.uptimeNanoseconds
        let followUp = strategy.followUpPrompt(for: result)
        let checked = await ToolOutcomeCheck.check(result, observation: followUp, monitor: outcomes)
        let framed = await ToolResultBoundary.frame(
            followUp: followUp,
            observation: checked.observation,
            toolName: toolName,
            session: boundary(for: conversationID)
        )
        return ToolCallResolution(
            records: [
                StageRecord(
                    stage: .toolDispatch,
                    outcome: Self.outcome(of: result),
                    durationMs: Int(elapsed / 1_000_000)
                ),
                checked.record,
                framed.record
            ],
            observation: checked.observation,
            refusal: nil,
            activity: Self.activity(for: result),
            result: result,
            keptContract: checked.keptContract,
            framedObservation: framed.observation
        )
    }

    /// OpenRouter routinely sends `"arguments": ""` for a tool with no parameters, and empty bytes
    /// fail `JSONDecoder` outright — every argument-less tool is broken until this maps them to an
    /// empty object.
    static func normalized(_ argumentsJSON: Data) -> Data {
        let text = String(data: argumentsJSON, encoding: .utf8) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Data("{}".utf8)
            : argumentsJSON
    }

    static func outcome(of result: ToolCallResult) -> StageOutcome {
        switch result.outcome {
        case .success:
            return .ran(detail: "\(result.toolName) → ok")
        case let .failure(error):
            switch error {
            case .unknownTool, .invalidArguments:
                // Model noise, not an outage. The description goes back as the observation and the
                // model corrects itself on the next hop; classifying these as `.failed` is exactly
                // how an app ends up saying "something went wrong" about a self-healing problem.
                return .ran(detail: "\(error.description) — returned to the model")
            case .handlerThrew:
                return .failed(message: error.description)
            }
        }
    }

    static func activity(for result: ToolCallResult) -> ToolActivity {
        switch result.outcome {
        case .success:
            return .finished(tool: result.toolName)
        case let .failure(error):
            guard case let .handlerThrew(_, message) = error else {
                return .cleared(tool: result.toolName)
            }
            return .failed(tool: result.toolName, message: message)
        }
    }

    private static func record(_ stage: PipelineStage, _ outcome: StageOutcome) -> StageRecord {
        StageRecord(stage: stage, outcome: outcome, durationMs: 0)
    }
}
