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
    /// When this message appeared. Shown in the details sheet — nothing recorded a time before,
    /// so a restored thread had no way to say when any of it happened.
    var createdAt: Date
    /// A note from `stanceGuard`: this answer gave up the previous one's position without new evidence.
    /// Kept apart from `text` so the history and the cache never carry it.
    var stanceNote: String?
    /// A note from `numberBinding`: figures in this answer that nothing the turn returned backs.
    /// Kept apart from `text` for the same reason as `stanceNote`.
    var numberNote: String?
    /// A note from `instructionCompliance`: instructions in the request this answer did not keep.
    var instructionNote: String?
    /// A note from `calendarCheck`: date arithmetic in this answer that the calendar does not bear out.
    var calendarNote: String?
    /// A note from `languageMatch`: sentences or words not in the language the user wrote in or asked for.
    var languageNote: String?
    /// A note from `packageCheck`: packages this answer installs that do not exist, or deserve a look.
    var packageNote: String?
    /// A note from `arithmeticCheck`: results this answer worked out that do not hold, with the exact value.
    var arithmeticNote: String?
    /// A note from `unitCheck`: unit conversions this answer made that do not hold, with the exact value.
    var unitNote: String?
    /// A note from `regexCheck`: regex claims in this answer that do not hold when run.
    var regexNote: String?
    /// A note from `stringCheck`: things this answer says about strings that do not hold when run.
    var stringNote: String?
    /// A note from `jsonCheck`: things this answer says about JSON that do not hold when parsed or run.
    var jsonNote: String?
    /// A note from `yamlCheck`: things this answer says about YAML that do not hold when parsed or loaded.
    var yamlNote: String?
    /// A note from `tomlCheck`: things this answer says about TOML that do not hold when parsed or loaded.
    var tomlNote: String?
    /// A note from `sqlCheck`: results this answer states for its SQL that do not hold when it runs.
    var sqlNote: String?

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        delivery: Delivery = .delivered,
        metrics: TurnCompletion? = nil,
        sources: [RetrievedSource] = [],
        followsCompaction: Bool = false,
        groundedFraction: Double? = nil,
        claimCount: Int = 0,
        createdAt: Date = Date()
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
        self.createdAt = createdAt
    }

    var isPending: Bool {
        delivery == .sending || delivery == .streaming
    }
}

extension ChatBubble {
    /// Copies what the post-model stages found in a delivered answer: how much of it is grounded, how
    /// many claims it makes, and the notes shown under it. One place, so a new stage's note cannot be
    /// computed and then silently dropped on the way to the screen.
    mutating func applyReview(_ review: AnswerReview) {
        groundedFraction = review.groundedFraction
        claimCount = review.claimCount
        stanceNote = review.stanceNote
        numberNote = review.numberNote
        instructionNote = review.instructionNote
        calendarNote = review.calendarNote
        languageNote = review.languageNote
        packageNote = review.packageNote
        arithmeticNote = review.arithmeticNote
        unitNote = review.unitNote
        regexNote = review.regexNote
        stringNote = review.stringNote
        jsonNote = review.jsonNote
        yamlNote = review.yamlNote
        tomlNote = review.tomlNote
        sqlNote = review.sqlNote
    }

    /// The notes the post-model stages left on this answer, in pipeline order, each with the accessibility
    /// identifier the UI tests look for. One list, so the view draws every note the same way.
    var reviewNotes: [ReviewNote] {
        let notes: [(String, String?)] = [
            ("stanceNote", stanceNote), ("numberNote", numberNote), ("instructionNote", instructionNote),
            ("calendarNote", calendarNote), ("languageNote", languageNote), ("packageNote", packageNote),
            ("arithmeticNote", arithmeticNote), ("unitNote", unitNote), ("regexNote", regexNote),
            ("stringNote", stringNote), ("jsonNote", jsonNote), ("yamlNote", yamlNote),
            ("tomlNote", tomlNote), ("sqlNote", sqlNote)
        ]
        return notes.compactMap { identifier, text in text.map { ReviewNote(id: identifier, text: $0) } }
    }
}

/// One note under an answer: what a post-model stage found, and the identifier it is drawn with.
struct ReviewNote: Identifiable, Equatable, Sendable {
    let id: String
    let text: String
}
