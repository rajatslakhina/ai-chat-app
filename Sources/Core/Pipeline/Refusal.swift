import Foundation

/// A refusal, in the shape the chat UI can render.
///
/// Every field exists because a refusal the user cannot act on is barely better than a silent
/// one: `headline` says what happened, `explanation` says why, and `recovery` says what to do
/// about it. A stage that refuses without filling these in fails review.
struct Refusal: Sendable, Equatable {
    let stage: PipelineStage
    let headline: String
    let explanation: String
    let recovery: RecoveryAction?

    enum RecoveryAction: Sendable, Equatable {
        case openSettings(field: String)
        case retryLater(after: Duration?)
        case switchModel
        case shortenConversation
        case approveTool(name: String)
        case addCredit
    }

    /// The button title for `recovery`, or nil when nothing can be done from here.
    var recoveryTitle: String? {
        switch recovery {
        case .openSettings: return "Open Settings"
        case let .retryLater(after):
            guard let after else { return "Try again" }
            return "Try again in \(after.components.seconds)s"
        case .switchModel: return "Choose another model"
        case .shortenConversation: return "Start a new conversation"
        case let .approveTool(name): return "Approve \(name)"
        case .addCredit: return "Add credit"
        case nil: return nil
        }
    }
}
