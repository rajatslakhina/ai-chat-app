import Foundation
import ProviderGatewayKit
import SwiftUI

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

    /// The tool call waiting on the user's signature, if the approval sheet is up.
    ///
    /// Mirrored from the gate rather than owned here: the gate is what the broker will actually
    /// consult, and a copy that drifted from it would show the user one call and sign another.
    private(set) var pendingApproval: ToolApprovalPrompt?

    let conversationID: String
    private let pipeline: PreModelPipeline
    private let executor: TurnExecutor
    private let review: PostModelPipeline
    /// Nil when no tool registry is wired, which is a legitimate configuration — the chat works,
    /// it just never proposes a tool call and so never asks for one to be approved.
    private let tools: ToolRoundTrip?
    /// Called whenever the thread's durable content changes, so the list and the on-disk history
    /// stay in step with what is on screen. Internal rather than private only so `persist()` can
    /// live beside the other derived members instead of padding the class body.
    let onPersist: (@MainActor ([StoredMessage], String) -> Void)?
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
        metadata: MetadataPipeline? = nil,
        tools: ToolRoundTrip? = nil,
        seed: [StoredMessage] = [],
        title: String = ChatViewModel.untitled,
        onPersist: (@MainActor ([StoredMessage], String) -> Void)? = nil
    ) {
        self.conversationID = conversationID
        self.pipeline = pipeline
        self.executor = executor
        self.review = review
        self.metadata = metadata
        self.tools = tools
        self.onPersist = onPersist
        self.conversationTitle = title
        // Restored as delivered, because that is what they are: a stored message is one the user
        // actually saw. Restoring delivery state would put a spinner on a turn nobody is awaiting.
        self.bubbles = seed.map {
            ChatBubble(
                id: $0.id,
                role: $0.role == .user ? .user : .assistant,
                text: $0.text,
                delivery: .delivered
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
        // Persist on every exit, not only the happy one: a turn that refused still leaves the
        // user's message on screen, and a list that had not recorded it would lose it on relaunch.
        defer {
            isSending = false
            persist()
        }

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
        //
        // And only a turn that carried no refusal is cached at all, which is `recordCompletion`'s
        // own stated contract — "caching a refusal poisons every later turn". Caching here defeats
        // the recovery the refusal just offered: a blocked tool call still publishes the model's
        // prose, so the turn ends `.delivered` with an answer that is missing whatever the tool
        // would have contributed. Store that, and approving the call and resending replays the
        // stale answer from the cache without ever calling the model again — the button appears to
        // do nothing, forever.
        if freshTrace.refusal == nil {
            await pipeline.recordCompletion(
                turn: turn,
                systemPrompt: turn.messages.first?.content,
                answer: reviewed.publishableText,
                providerID: completion.providerID
            )
        }
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

// MARK: - Tool approval

/// An extension rather than more class body, and not only to satisfy `type_body_length`: these
/// four members are the only ones that talk to the authority gate rather than to the turn
/// pipeline, and they read better grouped than interleaved with sending.
extension ChatViewModel {
    /// Fetches the call the gate is holding and raises the sheet.
    ///
    /// Asked for on demand rather than pushed up with the refusal, because a refusal reaches the
    /// UI as a `StageRecord` full of strings while the signature has to bind to the gate's own
    /// digest. Nothing pending means the turn was refused for some other reason and the sheet
    /// would have nothing truthful to show, so it does not open.
    func beginApproval() {
        guard let tools else { return }
        Task { pendingApproval = await tools.pendingApproval() }
    }

    /// Signs the pending call and resends, which is the only way the tool actually runs: the
    /// signature authorizes a digest, and only a fresh proposal of the same call presents it.
    func approvePending() {
        guard let tools else { return }
        pendingApproval = nil
        Task {
            // False means the gate had nothing to sign — a stale sheet, or a second tap. Resending
            // then would walk straight back into the same refusal and look like the button failed.
            guard await tools.approvePending(approver: Self.approver) else { return }
            retryLast()
        }
    }

    /// Dismisses the sheet without signing. The turn stays refused, which is the honest outcome.
    func declinePending() {
        pendingApproval = nil
        guard let tools else { return }
        Task { await tools.declinePending() }
    }
}

// MARK: - Message actions

/// Editing and retrying a specific message, rather than only the last turn.
///
/// Both truncate: everything after the message being acted on is discarded before the resend. The
/// alternative — leaving the later turns in place — produces a thread where the model's answers
/// respond to a question that is no longer above them, which reads as the app having lost track of
/// the conversation rather than as an edit.
extension ChatViewModel {
    /// True when a message can be edited or retried: it is the user's, and nothing is in flight.
    func canRevise(_ messageID: UUID) -> Bool {
        guard !isSending else { return false }
        return bubbles.contains { $0.id == messageID && $0.role == .user }
    }

    /// Sends the message again, discarding whatever it originally produced.
    func retry(_ messageID: UUID) {
        guard canRevise(messageID),
              let index = bubbles.firstIndex(where: { $0.id == messageID }) else { return }
        let text = bubbles[index].text
        truncate(from: index)
        sendTask = Task { await perform(text) }
    }

    /// Rewrites the message and sends the new version.
    ///
    /// An empty edit deletes nothing and sends nothing: a user who cleared the field and tapped
    /// Save almost certainly meant to cancel, and silently deleting their turn would be worse than
    /// ignoring them.
    func edit(_ messageID: UUID, to newText: String) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, canRevise(messageID),
              let index = bubbles.firstIndex(where: { $0.id == messageID }) else { return }
        guard trimmed != bubbles[index].text else { return }
        truncate(from: index)
        sendTask = Task { await perform(trimmed) }
    }

    /// The text of one message, for the edit sheet and for copying.
    func text(of messageID: UUID) -> String? {
        bubbles.first { $0.id == messageID }?.text
    }

    /// Drops the message at `index` and everything after it, and clears the state that described
    /// them — a refusal banner left behind would point at a turn that is no longer on screen.
    private func truncate(from index: Int) {
        bubbles.removeSubrange(index...)
        activeRefusal = nil
        followUps = []
        persist()
    }
}
