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

/// One pending approval, in the shape the sheet renders.
///
/// An app-side value rather than `ApprovalRequest` itself, so the approval UI does not import
/// `ToolAuthorityKit` and the sheet can be exercised without standing up a broker. Every field is
/// here because `ApprovalRequest`'s own documentation is right about what causes approval fatigue:
/// a prompt that says only "allow tool call?" gets tapped through, and the case actually worth
/// catching — a well-formed call whose arguments came out of a retrieved document — is invisible
/// without `provenance`.
struct ToolApprovalPrompt: Sendable, Equatable, Identifiable {
    let id: String
    let tool: String
    let resource: String
    let arguments: String
    let provenance: String
    /// True when the arguments were shaped by something the app retrieved rather than by the
    /// model's own reasoning. The sheet leads with this, because it is the one fact that turns a
    /// routine approval into one worth refusing.
    let isUntrusted: Bool

    init(request: ApprovalRequest) {
        self.id = request.digest
        self.tool = request.tool.raw
        self.resource = "\(request.resource)"
        self.arguments = request.arguments
        self.provenance = "\(request.provenance)"
        if case .untrusted = request.provenance {
            self.isUntrusted = true
        } else {
            self.isUntrusted = false
        }
    }
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
    private let baseCapabilities: [Capability]
    private let maxToolUses: Int
    private var openConversations: Set<String> = []

    /// When true every capability is issued with `requiresApproval`, so the broker answers
    /// `.approvalRequired` rather than allowing the call outright. Driven by a Settings toggle.
    private var requiresApproval: Bool

    /// The request the user is currently being asked to sign, if any.
    ///
    /// Held here rather than threaded out through the executor because a refusal reaches the UI as
    /// a `StageRecord`, and a `StageRecord` carries a `Refusal` — strings, deliberately. Widening
    /// that to carry an authority type would put `ToolAuthorityKit` into the trace's vocabulary
    /// for the sake of one screen.
    private var pendingRequest: ApprovalRequest?

    /// Signatures the user has given, keyed by the digest each one authorizes.
    ///
    /// Keyed by digest rather than by proposal id because `ProposalDigest` excludes the id on
    /// purpose: two proposals that would do exactly the same thing satisfy the same approval. That
    /// is what makes "approve, then resend" work at all — the retry re-proposes the identical call
    /// under a fresh id, and this is what recognises it.
    private var signedApprovals: [String: Approval] = [:]

    /// `ToolAuthorityKit` never reads a clock — lease boundaries are asserted against a
    /// caller-supplied tick — so the app owns the counter, exactly as it already does for
    /// `QuotaGovernorKit`. One tick per decision.
    private var tick = 0

    /// How many further decisions a signature stays good for.
    ///
    /// Bounded rather than unlimited: an approval that never expires is a standing permission the
    /// user was never asked for. Wide enough to survive the decisions a retry makes on its way
    /// back to the same call, narrow enough that a signature left behind by an abandoned turn does
    /// not authorize something the user has forgotten agreeing to.
    static let approvalValidityTicks = 64

    init(
        capabilities: [Capability],
        maxToolUses: Int = 32,
        requiresApproval: Bool = false,
        broker: AuthorityBroker = AuthorityBroker()
    ) {
        self.baseCapabilities = capabilities
        self.maxToolUses = maxToolUses
        self.requiresApproval = requiresApproval
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

    // MARK: - Approval

    /// Turns the human-signature requirement on or off.
    ///
    /// Every open grant is revoked, because capabilities are frozen into a `Grant` when it is
    /// issued — flipping the flag without re-issuing would leave the conversation running under
    /// the policy the user just changed away from, which is the one failure a settings toggle
    /// exists to prevent.
    func setRequiresApproval(_ newValue: Bool) async {
        guard newValue != requiresApproval else { return }
        requiresApproval = newValue
        for conversation in openConversations {
            _ = try? await broker.revoke(grantID: Self.grantID(for: conversation))
        }
        openConversations.removeAll()
        // Signatures were given under the old policy. Keeping them would let a toggle-off,
        // toggle-on round trip silently re-arm an approval the user gave for a different session.
        pendingRequest = nil
        signedApprovals.removeAll()
    }

    var isApprovalRequired: Bool { requiresApproval }

    /// The call waiting on a human, if one is.
    func pendingApproval() -> ToolApprovalPrompt? {
        pendingRequest.map(ToolApprovalPrompt.init(request:))
    }

    /// Signs the pending call so the next identical proposal is allowed.
    ///
    /// Returns false when nothing is pending — a stale sheet, or a second tap — so the caller can
    /// decline to resend rather than resend into the same refusal.
    func approvePending(approver: String) -> Bool {
        guard let request = pendingRequest else { return false }
        signedApprovals[request.digest] = Approval(
            id: UUID().uuidString,
            granting: request,
            approver: approver,
            validThroughTick: tick + Self.approvalValidityTicks
        )
        pendingRequest = nil
        approvalGeneration += 1
        return true
    }

    /// How many signatures the user has given, ever.
    ///
    /// Folded into the turn's `IdempotencyKey`. That key is otherwise the conversation, the model
    /// and the outbound text — so a resend after an approval is byte-identical to the send that
    /// was blocked, and the guard replays the blocked turn's stored result instead of calling the
    /// provider. Replaying is correct for a double-tapped Send and wrong here: a human has since
    /// authorized a tool call that could not run before, so it is not the same operation.
    var approvalGeneration = 0

    /// Drops the pending request without signing it. The turn stays refused, which is the point.
    func declinePending() {
        pendingRequest = nil
    }

    // MARK: - Decisions

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
            // Taken, not read. The broker spends a signature once and throws `approvalAlreadyUsed`
            // on a second presentation — and a throw becomes `.failed`, which would tell the user
            // the system broke when all they did was approve once and ask twice. Take-once here
            // mirrors spend-once there.
            let approval = signedApprovals.removeValue(forKey: proposal.digest)
            let decision = try await broker.authorize(proposal, at: tick, approval: approval)
            return verdict(for: decision, tool: tool)
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

    /// The capabilities as currently configured, with the signature requirement folded in.
    private var capabilities: [Capability] {
        guard requiresApproval else { return baseCapabilities }
        return baseCapabilities.map { capability in
            Capability(
                tool: capability.tool,
                actions: capability.actions,
                scope: capability.scope,
                maxProvenance: capability.maxProvenance,
                requiresApproval: true
            )
        }
    }

    /// Not static, unlike the rest: `.approvalRequired` has to record the request that came back,
    /// because the digest inside it is the only thing that can bind the user's signature to this
    /// exact call rather than to the tool in general.
    private func verdict(
        for decision: AuthorityDecision,
        tool: String
    ) -> ToolAuthorityVerdict {
        switch decision {
        case let .allowed(authorization):
            let remaining = authorization.usesRemaining.map(String.init) ?? "unlimited"
            let signature = authorization.approvedBy.map { " approved by \($0)," } ?? ""
            return .allowed(
                detail: "allowed \(tool) read on \(Self.resourcePath(for: tool)) via grant "
                    + "\(authorization.grantID),\(signature) \(remaining) use(s) left"
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
                    recovery: Self.recovery(for: reason, tool: tool)
                )
            )
        case let .approvalRequired(request):
            pendingRequest = request
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
