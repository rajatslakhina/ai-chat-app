import Foundation

/// What the view model computes rather than stores.
///
/// A separate file because none of it needs the class's private state — and because
/// `type_body_length` is a fair signal that a 270-line class body had stopped being one thing.
extension ChatViewModel {
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

    /// The thread in the shape the store keeps it.
    ///
    /// Only delivered bubbles. A refused or failed turn is a live-session artefact — restoring one
    /// would resurrect a banner for a message that was never sent, with nothing left to retry it
    /// against.
    var storedMessages: [StoredMessage] {
        bubbles.compactMap { bubble in
            guard bubble.delivery == .delivered else { return nil }
            return StoredMessage(
                id: bubble.id,
                role: bubble.role == .user ? .user : .assistant,
                text: bubble.text
            )
        }
    }

    /// Pushes the durable content out to whoever is storing it.
    func persist() {
        onPersist?(storedMessages, conversationTitle)
    }

    /// There is no account system, so the signature records the device's user as "you" rather than
    /// inventing an identity. `Authorization.approvedBy` carries it into the audit trail.
    static let approver = "you"
}
