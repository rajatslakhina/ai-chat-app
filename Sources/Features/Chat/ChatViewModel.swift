import Foundation
import ProviderGatewayKit
import SwiftUI

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

/// Drives one conversation.
///
/// `@MainActor` in full: every property here is read by SwiftUI during `body`, and the pipeline it
/// talks to is a set of actors reached with `await`. Keeping the boundary at this class means the
/// views never touch an actor and the actors never touch a view.
@MainActor
@Observable
final class ChatViewModel {
    private(set) var bubbles: [ChatBubble] = []
    private(set) var trace = PipelineTrace()
    private(set) var isSending = false
    /// The refusal to surface above the composer, if the last turn was refused.
    private(set) var activeRefusal: Refusal?
    /// What the navigation bar shows. Replaced once a turn has been named.
    private(set) var conversationTitle = ChatViewModel.untitled
    /// The tappable suggestions above the composer. Empty until a turn produces some, and emptied
    /// again the moment the next send starts — a chip suggesting a follow-up to a question that
    /// has already been superseded is worse than no chip.
    private(set) var followUps: [String] = []

    var draft: String = ""

    static let untitled = "AI Chat"

    let conversationID: String
    private let pipeline: PreModelPipeline
    private let executor: TurnExecutor
    private let review: PostModelPipeline
    /// Nil means this conversation is not named at all, which is a legitimate configuration —
    /// the chat works identically, it just keeps the default title.
    private let metadata: MetadataPipeline?
    private var sendTask: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?
    /// Which send the in-flight metadata belongs to. A generation that finishes after the user
    /// has already sent something else describes a conversation state that no longer exists.
    private var generation = 0
    /// Tools that ran during the turn in flight, in call order, so the settled chip can name all
    /// of them rather than only the last.
    private var toolsUsed: [String] = []

    init(
        conversationID: String = UUID().uuidString,
        pipeline: PreModelPipeline,
        executor: TurnExecutor,
        review: PostModelPipeline,
        metadata: MetadataPipeline? = nil
    ) {
        self.conversationID = conversationID
        self.pipeline = pipeline
        self.executor = executor
        self.review = review
        self.metadata = metadata
    }

    var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    /// History in the shape the pipeline wants — only bubbles that actually landed.
    ///
    /// A refused or failed turn must not enter the history it will be resent with, or the model
    /// ends up answering a question that was never delivered.
    var history: [ConversationMessage] {
        bubbles.compactMap { bubble in
            guard bubble.delivery == .delivered else { return nil }
            return ConversationMessage(
                id: bubble.id,
                role: bubble.role == .user ? .user : .assistant,
                text: bubble.text
            )
        }
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        draft = ""
        sendTask = Task { await perform(text) }
    }

    /// Sends a tapped suggestion.
    ///
    /// The chips are cleared before the send rather than after it, because leaving them on screen
    /// while the answer they were derived from scrolls away invites a second tap on a suggestion
    /// that is already in flight.
    func sendFollowUp(_ suggestion: String) {
        let text = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        draft = ""
        sendTask = Task { await perform(text) }
    }

    /// Cancels an in-flight turn. The bubble stays, marked, rather than vanishing.
    func stop() {
        sendTask?.cancel()
        sendTask = nil
        // A user who pressed Stop is not waiting for a title either, and a metadata call that
        // survived the cancel would keep spending on a turn they abandoned.
        metadataTask?.cancel()
        metadataTask = nil
        isSending = false
        if let index = bubbles.lastIndex(where: { $0.isPending }) {
            bubbles[index].delivery = .failed("Stopped")
        }
    }

    /// Re-sends the last user message after a refusal the user has resolved.
    func retryLast() {
        guard let last = bubbles.last(where: { $0.role == .user }) else { return }
        activeRefusal = nil
        bubbles.removeAll { $0.role == .assistant && $0.delivery != .delivered }
        sendTask = Task { await perform(last.text) }
    }

    private func perform(_ text: String) async {
        isSending = true
        activeRefusal = nil
        followUps = []
        generation += 1
        metadataTask?.cancel()
        metadataTask = nil
        defer { isSending = false }

        let priorHistory = history
        let userBubble = ChatBubble(role: .user, text: text, delivery: .sending)
        bubbles.append(userBubble)

        var freshTrace = PipelineTrace()
        let preparation = await pipeline.prepare(
            userText: text,
            history: priorHistory,
            trace: &freshTrace
        )
        trace = freshTrace

        switch preparation {
        case let .refused(refusal):
            markUser(userBubble.id, .refused(refusal))
            activeRefusal = refusal

        case let .cached(answer, providerID):
            markUser(userBubble.id, .delivered)
            bubbles.append(
                ChatBubble(
                    role: .assistant,
                    text: answer,
                    delivery: .delivered,
                    metrics: TurnCompletion(
                        text: answer,
                        providerID: providerID,
                        promptTokens: 0,
                        completionTokens: 0,
                        reportedCostUSD: 0,
                        meteredCostUSD: 0,
                        attempts: 1
                    )
                )
            )

        case let .ready(turn):
            await stream(turn, userBubbleID: userBubble.id, trace: &freshTrace)
        }
    }

    private func stream(
        _ turn: PreparedTurn,
        userBubbleID: UUID,
        trace freshTrace: inout PipelineTrace
    ) async {
        markUser(userBubbleID, .delivered)
        let assistant = ChatBubble(
            role: .assistant,
            text: "",
            delivery: .streaming,
            sources: turn.sources,
            followsCompaction: turn.didCompact
        )
        bubbles.append(assistant)
        let assistantID = assistant.id
        toolsUsed = []

        let result = await executor.execute(
            turn,
            conversationID: conversationID,
            trace: &freshTrace,
            onDelta: { [weak self] fragment in
                Task { @MainActor in self?.appendFragment(fragment, to: assistantID) }
            },
            onTool: { [weak self] activity in
                Task { @MainActor in self?.apply(activity, to: assistantID) }
            }
        )
        trace = freshTrace

        switch result {
        case let .completed(completion):
            await publish(completion, turn: turn, to: assistantID, trace: &freshTrace)
        case let .refused(refusal):
            update(assistantID) { $0.delivery = .refused(refusal) }
            activeRefusal = refusal
        case let .failed(message):
            update(assistantID) { $0.delivery = .failed(message) }
        }
    }

    /// Reviews a completed answer, then shows it.
    ///
    /// The review runs before anything reaches the screen: a redaction or an unsupported claim has
    /// to change what the user sees, not just what a log records.
    private func publish(
        _ completion: TurnCompletion,
        turn: PreparedTurn,
        to assistantID: UUID,
        trace freshTrace: inout PipelineTrace
    ) async {
        let reviewed = await review.review(
            answer: completion.text,
            sources: turn.sources,
            trace: &freshTrace
        )
        trace = freshTrace

        if let refusal = reviewed.refusal {
            update(assistantID) { bubble in
                // The fragments already on screen are exactly what the output guardrail just
                // withheld — they were rendered as they streamed, before anything had judged
                // them. Leaving them there makes the refusal cosmetic: the banner says the answer
                // was withheld while the answer is still readable underneath it.
                bubble.text = reviewed.publishableText
                bubble.delivery = .refused(refusal)
            }
            activeRefusal = refusal
            return
        }
        update(assistantID) { bubble in
            // The reviewed text wins over the accumulated fragments: a replayed turn streams
            // nothing, and the fragments alone would leave the bubble empty.
            if !reviewed.publishableText.isEmpty { bubble.text = reviewed.publishableText }
            bubble.delivery = .delivered
            bubble.metrics = completion
            bubble.groundedFraction = reviewed.groundedFraction
            bubble.claimCount = reviewed.claimCount
        }
        // A tool call the authority gate declined does not throw the answer away: the model's own
        // prose still publishes, and the refusal renders above the composer underneath it. The
        // user is told what was not done, next to what was.
        if let refusal = freshTrace.refusal { activeRefusal = refusal }
        // Only the text the user actually saw is cached. Caching the unreviewed answer would
        // serve the un-redacted version on the next identical question.
        await pipeline.recordCompletion(
            turn: turn,
            systemPrompt: turn.messages.first?.content,
            answer: reviewed.publishableText,
            providerID: completion.providerID
        )
        // Named from the *reviewed* text, for the same reason the cache is: a title derived from
        // an answer the guardrail redacted would put the redacted span back on screen, in the
        // navigation bar, where it is visible on every screenshot.
        nameConversation(userText: turn.displayUserText, assistantText: reviewed.publishableText)
    }

    /// Kicks off metadata generation for a turn that has landed.
    ///
    /// Detached from the send, because none of it is what the user asked for: the composer
    /// re-enables on the same frame it otherwise would, and the title and chips arrive when they
    /// arrive.
    private func nameConversation(userText: String, assistantText: String) {
        guard let metadata else { return }
        let token = generation
        metadataTask = Task { [weak self] in
            var metadataTrace = PipelineTrace()
            let result = await metadata.generate(
                userText: userText,
                assistantText: assistantText,
                trace: &metadataTrace
            )
            guard let self, !Task.isCancelled else { return }
            self.applyMetadata(result, trace: metadataTrace, from: token)
        }
    }

    /// Folds a finished metadata generation into the UI and the trace.
    ///
    /// Not private so the staleness rule can be asserted directly: a generation that lands after
    /// the user has already sent something else is describing a conversation that has moved on,
    /// and applying it would retitle the screen from a question two turns old.
    func applyMetadata(_ result: ChatMetadata?, trace metadataTrace: PipelineTrace, from token: Int) {
        guard token == generation else { return }
        for record in metadataTrace.records {
            trace.record(record.stage, record.outcome, durationMs: record.durationMs)
        }
        guard let result else { return }
        conversationTitle = result.title
        followUps = result.followUps
    }

    /// Folds one tool-activity event into the assistant bubble's chip.
    ///
    /// Not private so the transitions can be asserted directly. The running chip exists for a
    /// window measured in hundreds of milliseconds, and a test that tried to catch it mid-flight
    /// would be asserting on a race rather than on behaviour.
    func apply(_ activity: ToolActivity, to id: UUID) {
        switch activity {
        case let .started(tool):
            update(id) { $0.toolState = .running(tool) }
        case let .finished(tool):
            toolsUsed.append(tool)
            let names = toolsUsed
            update(id) { $0.toolState = .used(names) }
        case .cleared:
            let names = toolsUsed
            update(id) { $0.toolState = names.isEmpty ? .idle : .used(names) }
        case let .failed(tool, message):
            update(id) { $0.toolState = .failed(tool: tool, message: message) }
        }
    }

    private func appendFragment(_ fragment: String, to id: UUID) {
        update(id) { $0.text += fragment }
    }

    private func markUser(_ id: UUID, _ delivery: ChatBubble.Delivery) {
        update(id) { $0.delivery = delivery }
    }

    private func update(_ id: UUID, _ mutate: (inout ChatBubble) -> Void) {
        guard let index = bubbles.firstIndex(where: { $0.id == id }) else { return }
        mutate(&bubbles[index])
    }
}
