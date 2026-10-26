import InstructionComplianceKit

/// The conversation's instructions as of this turn.
///
/// Rebuilt from the user's own messages every turn rather than kept in a long-lived session, so a
/// restored conversation carries "from now on, answer in lowercase" exactly as the live one did, and
/// nothing about a turn depends on which process happened to see the earlier ones.
enum InstructionPlanner {
    /// `userTexts` in order, the current message last. Nil when there is no current message.
    static func plan(userTexts: [String]) async -> TurnPlan? {
        guard let current = userTexts.last else { return nil }
        let session = ComplianceSession()
        for earlier in userTexts.dropLast() {
            await session.begin(request: earlier)
        }
        return await session.begin(request: current)
    }
}

extension PreModelPipeline {
    /// The refusals that need only the message, the history and the tool catalog, all free: a catalog
    /// that changed since it was approved, then instructions that contradict each other. One call so
    /// `prepare` stays inside its body limit.
    static func earlyRefusal(
        _ userText: String,
        _ history: [ConversationMessage],
        _ trace: inout PipelineTrace
    ) async -> Refusal? {
        if let refusal = await toolIntegrityRefusal(trace: &trace) { return refusal }
        return await instructionConflictRefusal(userText: userText, history: history, trace: &trace)
    }

    /// Instructions that no answer can follow together, found before the provider call.
    ///
    /// "At most 2 sentences, across at least 3 paragraphs", "use the word 'latency'" with "never use
    /// the word 'latency'", valid JSON as a bulleted list: whatever the model sends back breaks one of
    /// them, and the post-model check would then report a violation the user made inevitable. This is
    /// free work, so it belongs before the turn is paid for.
    ///
    /// A refusal, because sending the request anyway charges the user for an answer that cannot do what
    /// they asked. The message goes back into the composer so the user can say which one they meant.
    static func instructionConflictRefusal(
        userText: String,
        history: [ConversationMessage],
        trace: inout PipelineTrace
    ) async -> Refusal? {
        let earlier = history.filter { $0.role == .user }.map(\.text)
        guard let plan = await InstructionPlanner.plan(userTexts: earlier + [userText]),
              !plan.directives.isEmpty else {
            trace.record(.instructionConflict, .noOp(reason: "no instructions a program can check"))
            return nil
        }
        guard let conflict = plan.conflicts.first else {
            let carried = plan.carried.isEmpty ? "" : ", \(plan.carried.count) carried from earlier turns"
            let count = plan.directives.count == 1 ? "1 instruction" : "\(plan.directives.count) instructions"
            let detail = "\(count)\(carried), none conflict"
            trace.record(.instructionConflict, .ran(detail: detail))
            return nil
        }
        let refusal = Refusal(
            stage: .instructionConflict,
            headline: "Your instructions contradict each other",
            explanation: "\"\(conflict.first.summary)\" and \"\(conflict.second.summary)\" can't both hold: "
                + "\(conflict.reason). Nothing was sent, so nothing was charged. Say which one you want.",
            recovery: .rephrase
        )
        trace.record(.instructionConflict, .refused(refusal))
        return refusal
    }
}
