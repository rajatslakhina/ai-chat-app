import Foundation
import OutputRepairKit
import StructuredOutputKit

/// Decides whether one raw model reply is worth decoding, and explains every rejection as a
/// `RepairIssue` the repair loop can feed back verbatim.
///
/// `Output` is the accepted JSON *text* rather than a decoded value, and that is not a shortcut.
/// `OutputContract.validate` is synchronous and non-throwing while `StructuredOutputDecoder` is
/// an actor, so the typed decode provably cannot happen inside this method. What can happen here
/// is every check that decides whether the text deserves a decode — which is exactly the half of
/// `StructuredOutputDecoder.decode` that produces an actionable message instead of a
/// `DecodingError`. The typed decode runs once, afterwards, on the text this accepted.
struct MetadataContract: OutputContract, Sendable {
    let schema: JSONSchema
    /// The rules a JSON Schema cannot state: how many follow-ups is too many, how long a title
    /// may be. Every broken rule is returned at once, because a repair prompt that lists all of
    /// them converges in one round trip where one that reveals them singly needs several.
    let rules: @Sendable ([String: JSONValue]) -> [RepairIssue]

    func validate(_ raw: String) -> ContractResult<String> {
        guard let found = Self.jsonObject(in: raw) else {
            return .invalid([Self.notJSONIssue(raw)])
        }
        if let mismatch = SchemaValidator.firstMismatch(of: .object(found.fields), against: schema) {
            return .invalid([RepairIssue(path: "", problem: mismatch)])
        }
        let broken = rules(found.fields)
        // `.invalid([])` is legal in OutputRepairKit and produces a repair prompt reading "fix
        // exactly these 0 problem(s)" — a billed round trip carrying no instruction. Nothing in
        // the type system prevents it, so the guard is here.
        guard broken.isEmpty else { return .invalid(broken) }
        return .valid(found.text)
    }

    /// The JSON object inside a model reply, together with the exact substring it was found in.
    ///
    /// `JSONExtractor` does the unwrapping: models wrap JSON in ```json fences and bracket it with
    /// prose constantly, and a contract that rejected those would spend its whole attempt budget
    /// teaching the model to stop doing something it will keep doing.
    static func jsonObject(in raw: String) -> (text: String, fields: [String: JSONValue])? {
        guard let substring = JSONExtractor.extractJSONSubstring(from: raw),
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(substring.utf8)),
              case let .object(fields) = value else { return nil }
        return (substring, fields)
    }

    static func notJSONIssue(_ raw: String) -> RepairIssue {
        RepairIssue(
            path: "",
            problem: "the reply did not contain a JSON object",
            expected: "a single JSON object",
            observed: excerpt(of: raw)
        )
    }

    /// A short, quoted sample of the rejected reply.
    ///
    /// Short on purpose. The excerpt travels into a repair prompt and, from there, into the trace
    /// — and a rejected reply in a chat app routinely echoes the user's own message back.
    static func excerpt(of raw: String) -> String {
        let flattened = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flattened.isEmpty else { return "an empty reply" }
        guard flattened.count > 60 else { return "\"\(flattened)\"" }
        return "\"\(flattened.prefix(60))…\""
    }
}

/// The checks that live above the schema.
///
/// Every one of these is a real defect the schema would pass: four follow-up chips do not fit,
/// two identical chips look like a bug, and a title that runs to a paragraph is a navigation bar
/// showing an ellipsis. They are written as free functions over the validated field dictionary so
/// they can be tested directly rather than only through a whole repair loop.
enum MetadataRules {
    static func title(_ fields: [String: JSONValue]) -> [RepairIssue] {
        // Unreachable through `MetadataContract`, which runs the schema check first and so has
        // already proved `title` is a present string. Kept because these are public rules over a
        // loose dictionary, and "no opinion about a field that is not there" is the right answer.
        guard case let .string(raw)? = fields["title"] else { return [] }
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var issues: [RepairIssue] = []
        if title.isEmpty {
            issues.append(
                RepairIssue(
                    path: "title",
                    problem: "the title was blank",
                    expected: "1 to \(ChatMetadata.maxTitleCharacters) characters",
                    observed: "an empty string"
                )
            )
        } else if title.count > ChatMetadata.maxTitleCharacters {
            issues.append(
                RepairIssue(
                    path: "title",
                    problem: "the title is too long for a navigation bar",
                    expected: "at most \(ChatMetadata.maxTitleCharacters) characters",
                    observed: "\(title.count) characters"
                )
            )
        }
        if title.contains("\n") {
            issues.append(
                RepairIssue(
                    path: "title",
                    problem: "the title spans more than one line",
                    expected: "a single line",
                    observed: "a title containing a line break"
                )
            )
        }
        return issues
    }

    static func followUps(_ fields: [String: JSONValue]) -> [RepairIssue] {
        // Same reasoning as `title`: the schema check has already run by the time the contract
        // calls this, so the early return only fires for a direct caller.
        guard case let .array(items)? = fields["followUps"] else { return [] }
        let suggestions = items.compactMap(Self.text)
        var issues = countIssues(suggestions.count)
        issues.append(contentsOf: lengthIssues(suggestions))
        if Set(suggestions).count != suggestions.count {
            issues.append(
                RepairIssue(
                    path: "followUps",
                    problem: "two suggestions are identical",
                    expected: "distinct questions",
                    observed: "a repeated question"
                )
            )
        }
        return issues
    }

    private static func countIssues(_ count: Int) -> [RepairIssue] {
        let allowed = ChatMetadata.minFollowUps...ChatMetadata.maxFollowUps
        guard !allowed.contains(count) else { return [] }
        return [
            RepairIssue(
                path: "followUps",
                problem: "the wrong number of suggestions",
                expected: "\(allowed.lowerBound) to \(allowed.upperBound) items",
                observed: "\(count) item(s)"
            )
        ]
    }

    private static func lengthIssues(_ suggestions: [String]) -> [RepairIssue] {
        suggestions.enumerated().compactMap { index, suggestion in
            let trimmed = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return RepairIssue(
                    path: "followUps[\(index)]",
                    problem: "the suggestion was blank",
                    expected: "a question",
                    observed: "an empty string"
                )
            }
            guard trimmed.count > ChatMetadata.maxFollowUpCharacters else { return nil }
            return RepairIssue(
                path: "followUps[\(index)]",
                problem: "the suggestion is too long to fit on a chip",
                expected: "at most \(ChatMetadata.maxFollowUpCharacters) characters",
                observed: "\(trimmed.count) characters"
            )
        }
    }

    private static func text(_ value: JSONValue) -> String? {
        guard case let .string(text) = value else { return nil }
        return text
    }
}
