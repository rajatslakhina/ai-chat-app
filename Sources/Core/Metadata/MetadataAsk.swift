import Foundation
import StructuredOutputKit

/// One thing the app asks a model for after a turn has been paid for and shown.
///
/// The two asks are separate values rather than two methods so they can be handed to
/// `BatchInferenceKit` as a list and fanned out. `id` doubles as the batch request id, which is
/// what makes `BatchReport.text(for:)` a direct lookup instead of an index into a parallel array.
struct MetadataAsk: Sendable {
    let id: String
    let system: String
    let contract: MetadataContract
    /// The shape instructions appended to every prompt, rendered by `PromptBuilder` from the same
    /// `JSONSchema` the contract validates against — so the model is told exactly what its answer
    /// will be checked for, rather than a prose paraphrase that can drift from it.
    let instruction: String

    /// The prompt one ask goes out with.
    ///
    /// The assistant's answer is truncated: naming a conversation needs its subject, not its
    /// whole transcript, and a metadata call that grows with the answer it describes is a cost
    /// that climbs for no benefit.
    func prompt(userText: String, assistantText: String) -> String {
        """
        The user asked:
        \(userText.prefix(400))

        The assistant answered:
        \(assistantText.prefix(600))

        \(instruction)
        """
    }
}

extension MetadataAsk {
    static let titleID = "chat.metadata.title"
    static let followUpsID = "chat.metadata.followups"

    static let title = MetadataAsk(
        id: titleID,
        system: "You label conversations. Answer with one JSON object and nothing else.",
        contract: MetadataContract(
            schema: ChatTitleDraft.jsonSchema,
            rules: MetadataRules.title
        ),
        instruction: PromptBuilder.instructions(
            for: ChatTitleDraft.jsonSchema,
            typeName: "the conversation title"
        )
    )

    static let followUps = MetadataAsk(
        id: followUpsID,
        system: "You suggest what a user might ask next. Answer with one JSON object and nothing else.",
        contract: MetadataContract(
            schema: ChatFollowUpsDraft.jsonSchema,
            rules: MetadataRules.followUps
        ),
        instruction: PromptBuilder.instructions(
            for: ChatFollowUpsDraft.jsonSchema,
            typeName: "the follow-up suggestions"
        )
    )

    /// Both asks, in the order their answers are read. `BatchReport.outcomes` is guaranteed to
    /// follow input order, so this order is also the order the trace reports them in.
    static let all: [MetadataAsk] = [title, followUps]
}
