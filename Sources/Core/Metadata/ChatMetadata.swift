import Foundation
import StructuredOutputKit

/// Who wrote the conversation title.
///
/// A v2 field. It exists because the two titles are not interchangeable: a model-written title
/// summarises the conversation, and a fallback is the opening words of the user's own message
/// with an ellipsis on the end. Storing which one is on screen is what lets a later build offer
/// "rename this conversation" only where renaming would actually improve anything.
enum TitleSource: String, Decodable, Sendable, Equatable {
    case model
    case fallback
}

/// The field schemas the three metadata types are assembled from.
///
/// One declaration per field rather than one per type: `ChatMetadata` is the union of the two
/// drafts, and a hand-copied duplicate of the same schema node is how the prompt the model is
/// given drifts away from the schema its answer is checked against.
enum MetadataField {
    static let title = JSONSchema.string(
        description: "a title for this conversation, at most six words, no trailing punctuation"
    )

    static let followUps = JSONSchema.array(
        of: .string(description: "a question the user might plausibly ask next, in their voice"),
        description: "two or three follow-up questions"
    )

    static let titleSource = JSONSchema.string(
        description: "who wrote the title",
        enumValues: [TitleSource.model.rawValue, TitleSource.fallback.rawValue]
    )
}

/// The title half of the metadata, asked for on its own.
///
/// Split from the follow-ups rather than asked for in one object because the two are fanned out
/// concurrently, and because one malformed field must not cost the other one. A conversation that
/// gets a title and no chips is better than one that gets neither.
struct ChatTitleDraft: Decodable, Sendable, Equatable, JSONSchemaConvertible {
    let title: String

    static var jsonSchema: JSONSchema {
        .object(properties: ["title": MetadataField.title], required: ["title"])
    }
}

/// The follow-up half of the metadata, asked for on its own.
struct ChatFollowUpsDraft: Decodable, Sendable, Equatable, JSONSchemaConvertible {
    let followUps: [String]

    static var jsonSchema: JSONSchema {
        .object(properties: ["followUps": MetadataField.followUps], required: ["followUps"])
    }
}

/// Everything the app knows about one conversation beyond its messages.
///
/// This is the v2 shape — the one the navigation bar and the chip row read. The model is asked
/// for the v1 shape (`title` + `followUps`), because `titleSource` is a fact about the app rather
/// than about the conversation and a model asked for it would simply guess.
struct ChatMetadata: Decodable, Sendable, Equatable, JSONSchemaConvertible {
    let title: String
    let followUps: [String]
    let titleSource: TitleSource

    static var jsonSchema: JSONSchema {
        .object(
            properties: [
                "title": MetadataField.title,
                "followUps": MetadataField.followUps,
                "titleSource": MetadataField.titleSource
            ],
            required: ["title", "followUps", "titleSource"]
        )
    }

    /// The rules the JSON schema cannot express, kept here so the contract and the UI agree on
    /// them. A title longer than this is not invalid JSON — it is a navigation bar that truncates.
    static let maxTitleCharacters = 48
    static let minFollowUps = 2
    static let maxFollowUps = 3
    static let maxFollowUpCharacters = 72

    /// The title shown when no model produced one.
    ///
    /// Deliberately the user's own words rather than "Untitled": a sidebar full of "Untitled" is
    /// indistinguishable from a sidebar that has lost its data, and the first few words of what
    /// someone actually typed identify a conversation better than any generated label does.
    static func fallbackTitle(from userText: String) -> String {
        let flattened = userText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flattened.isEmpty else { return "New conversation" }
        guard flattened.count > maxTitleCharacters else { return flattened }
        return String(flattened.prefix(maxTitleCharacters - 1)) + "…"
    }

    /// The metadata used when the model could not name the conversation.
    static func fallback(userText: String, followUps: [String] = []) -> ChatMetadata {
        ChatMetadata(
            title: fallbackTitle(from: userText),
            followUps: followUps,
            titleSource: .fallback
        )
    }
}
