import Foundation
import ToolAuthorityKit

/// What the authority gate decided, in the app's own vocabulary.
///
/// Four cases rather than `AuthorityDecision`'s three, because the host's own mistakes — the
/// things `AuthorityBroker` throws rather than returns — are a fourth kind of answer and must not
/// be laundered into a denial. A denial is policy working; a thrown `AuthorityError` means this
/// app's model of the policy disagrees with the broker's, which is a defect.
enum ToolAuthorityVerdict: Sendable, Equatable {
    case allowed(detail: String)
    case denied(Refusal)
    case approvalRequired(Refusal)
    case failed(message: String)
}

/// Asks `AuthorityBroker` whether a tool call the model proposed may actually run.
///
/// The model's chosen tool call is a proposal, not a command. Everything here exists so that a
/// call whose arguments were shaped by a retrieved document cannot exercise an authority that only
/// admits model-authored input — the one defence against indirect prompt injection that does not
/// depend on the model behaving.
actor ToolAuthorityGate {
    /// Injectable only so the `.failed` verdict can be reached. `AuthorityBroker.issue` throws on
    /// a grant id that is already held, and a gate that owns its broker outright can never collide
    /// with itself — which leaves the one verdict that means "this app disagrees with the broker"
    /// asserted by reasoning rather than by running it.
    private let broker: AuthorityBroker
    private let capabilities: [Capability]
    private let maxToolUses: Int
    private var openConversations: Set<String> = []

    /// `ToolAuthorityKit` never reads a clock — lease boundaries are asserted against a
    /// caller-supplied tick — so the app owns the counter, exactly as it already does for
    /// `QuotaGovernorKit`. One tick per decision.
    private var tick = 0

    init(
        capabilities: [Capability],
        maxToolUses: Int = 32,
        broker: AuthorityBroker = AuthorityBroker()
    ) {
        self.capabilities = capabilities
        self.maxToolUses = maxToolUses
        self.broker = broker
    }

    /// The grant id one conversation's lease is held under, exposed so a test can occupy it.
    static func grantID(for conversationID: String) -> String { "conv-\(conversationID)" }

    /// The capability set for tools that only observe.
    ///
    /// `maxProvenance` is left at `.modelAuthored` deliberately: a call the model composed from
    /// its own reasoning may run, and a call composed from a page the app retrieved may not.
    static func readOnly(tools: [String]) -> [Capability] {
        tools.map { name in
            Capability(
                tool: ToolName(name),
                actions: [.read],
                scope: .subtree(ResourcePath(Self.resourcePath(for: name))),
                maxProvenance: .modelAuthored
            )
        }
    }

    static func resourcePath(for tool: String) -> String { "tools/\(tool)" }

    func decide(
        tool: String,
        arguments: String,
        conversationID: String,
        provenance: Provenance
    ) async -> ToolAuthorityVerdict {
        do {
            try await openIfNeeded(conversationID)
            tick += 1
            // Never constructed without an explicit `provenance`: the parameter defaults to
            // `.untrusted(source: "unspecified")`, which denies against every capability here.
            let proposal = ToolProposal(
                id: "\(conversationID)#\(tick)",
                principal: conversationID,
                tool: ToolName(tool),
                action: .read,
                resource: ResourcePath(Self.resourcePath(for: tool)),
                arguments: arguments,
                provenance: provenance
            )
            return Self.verdict(for: try await broker.authorize(proposal, at: tick), tool: tool)
        } catch {
            return .failed(message: "\(error)")
        }
    }

    /// Revokes a conversation's grant, cascading to anything delegated from it.
    func close(conversationID: String) async {
        guard openConversations.remove(conversationID) != nil else { return }
        // An unknown grant on this path just means the conversation never used a tool.
        _ = try? await broker.revoke(grantID: Self.grantID(for: conversationID))
    }

    func statistics() async -> AuthorityStatistics {
        await broker.statistics()
    }

    func trail() async -> [AuthorityEvent] {
        await broker.trail()
    }

    /// The principal is the conversation, never the signed-in user. An agent is a principal in its
    /// own right rather than a borrower of whoever launched it, which is what makes revoking one
    /// conversation's tool access a thing that can be done at all.
    private func openIfNeeded(_ conversationID: String) async throws {
        guard !openConversations.contains(conversationID) else { return }
        try await broker.issue(
            Grant(
                id: Self.grantID(for: conversationID),
                principal: conversationID,
                task: "chat",
                capabilities: capabilities,
                maxUses: maxToolUses
            )
        )
        openConversations.insert(conversationID)
    }

    private static func verdict(
        for decision: AuthorityDecision,
        tool: String
    ) -> ToolAuthorityVerdict {
        switch decision {
        case let .allowed(authorization):
            let remaining = authorization.usesRemaining.map(String.init) ?? "unlimited"
            return .allowed(
                detail: "allowed \(tool) read on \(resourcePath(for: tool)) via grant "
                    + "\(authorization.grantID), \(remaining) use(s) left"
            )
        case let .denied(reason):
            return .denied(
                Refusal(
                    stage: .toolAuthority,
                    headline: "Tool call blocked",
                    // `DenialReason.description` is written to be read by a human on a pager —
                    // "resource 'x' is outside scope 'y'" — so it is used verbatim rather than
                    // paraphrased into something vaguer.
                    explanation: "\(reason)",
                    recovery: recovery(for: reason, tool: tool)
                )
            )
        case let .approvalRequired(request):
            return .approvalRequired(
                Refusal(
                    stage: .toolAuthority,
                    headline: "Approval needed",
                    explanation: "The assistant wants to run \(request.tool) "
                        + "on \(request.resource) with arguments \(request.arguments).",
                    recovery: .approveTool(name: tool)
                )
            )
        }
    }

    /// A lease that ran out of time or volume cannot be approved back into existence, so offering
    /// "Approve calculator" for it would be a button that does nothing. Every other denial is a
    /// permission question, and approving the tool is exactly the action that resolves it.
    private static func recovery(
        for reason: DenialReason,
        tool: String
    ) -> Refusal.RecoveryAction {
        switch reason {
        case .grantExpired, .grantExhausted:
            return .shortenConversation
        default:
            return .approveTool(name: tool)
        }
    }
}
