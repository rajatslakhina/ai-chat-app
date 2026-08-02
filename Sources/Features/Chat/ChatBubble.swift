import Foundation
import ProviderGatewayKit

/// One bubble in the thread, as the UI holds it.
///
/// Deliberately owned by the view model rather than read back from `LLMSession.currentTranscript()`
/// — the gateway drops the user's message when a turn fails, which is correct for a transcript it
/// will resend but wrong for a chat log, where the message the user typed must stay on screen with
/// a way to retry it.
struct ChatBubble: Identifiable, Equatable, Sendable {
    enum Role: Equatable, Sendable { case user, assistant }

    enum Delivery: Equatable, Sendable {
        case sending
        case streaming
        case delivered
        case refused(Refusal)
        case failed(String)
    }

    /// What the tool round trip should say under this bubble.
    ///
    /// `used` and `failed` are separate cases because a tool that ran and a tool that broke are
    /// different facts, and only the second one is the user's problem. A blocked call is neither:
    /// the refusal banner already speaks for it, so the chip goes back to silence.
    enum ToolState: Equatable, Sendable {
        /// Named `idle` rather than `none`: an optional `ToolState?` would make `.none` mean two
        /// different things at every call site, and the compiler resolves that in Optional's favour.
        case idle
        case running(String)
        case used([String])
        case failed(tool: String, message: String)
    }

    /// Not part of the initializer: it is set as the turn runs rather than when the bubble is
    /// created, and every call site would otherwise pass `.none`.
    var toolState: ToolState = .idle

    let id: UUID
    let role: Role
    var text: String
    var delivery: Delivery
    /// Filled in once the turn completes, for the caption under the bubble.
    var metrics: TurnCompletion?
    var sources: [RetrievedSource]
    /// True when compaction dropped earlier turns before this one was sent.
    var followsCompaction: Bool
    /// Share of claims a source supported, when grounding ran.
    var groundedFraction: Double?
    /// Claims checked, so the caption can say "3 of 4" rather than a bare percentage.
    var claimCount: Int

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        delivery: Delivery = .delivered,
        metrics: TurnCompletion? = nil,
        sources: [RetrievedSource] = [],
        followsCompaction: Bool = false,
        groundedFraction: Double? = nil,
        claimCount: Int = 0
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.delivery = delivery
        self.metrics = metrics
        self.sources = sources
        self.followsCompaction = followsCompaction
        self.groundedFraction = groundedFraction
        self.claimCount = claimCount
    }

    var isPending: Bool {
        delivery == .sending || delivery == .streaming
    }
}
