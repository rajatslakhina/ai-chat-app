import Foundation
import NumberBindingKit
import ProviderGatewayKit
import ToolRegistryKit

/// One successful tool call's result, as the JSON text the tool returned.
struct ToolOutput: Sendable, Equatable {
    let tool: String
    let text: String
}

extension ToolOutput {
    /// Nil for a failed call: an error message is not evidence for a number.
    init?(_ result: ToolCallResult) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard case let .success(value) = result.outcome, let data = try? encoder.encode(value),
              let text = String(bytes: data, encoding: .utf8) else { return nil }
        self.init(tool: result.toolName, text: text)
    }
}

/// Everything a number in the answer may be bound to this turn.
struct NumberEvidence: Equatable {
    let toolOutputs: [ToolOutput]
    let sources: [RetrievedSource]
    let messages: [LLMMessage]

    /// Tool results and retrieved passages are evidence. So is everything the user wrote in this
    /// conversation. Earlier assistant answers are not: their figures can only make a number `echoed`,
    /// because the model cannot vouch for a number by repeating it.
    var numberSources: [NumberSource] {
        let tools = toolOutputs.map { NumberSource.tool($0.tool, output: $0.text) }
        let documents = sources.map { NumberSource.document(id: $0.id, title: $0.title, text: $0.snippet) }
        let user = messages.filter { $0.role == .user }.enumerated().map {
            NumberSource(id: "user:\($0.offset)", kind: .user, label: "your message",
                         text: $0.element.content)
        }
        let earlier = messages.filter { $0.role == .assistant }.enumerated().map {
            NumberSource.earlierAnswer($0.element.content, index: $0.offset + 1)
        }
        return tools + documents + user + earlier
    }
}

extension PostModelPipeline {
    /// Whether every number in the answer is one the turn actually had.
    ///
    /// Grounding scores sentences by overlap, and a sentence with one wrong figure overlaps its source
    /// almost perfectly. This stage reads each figure in the answer and binds it to a figure in a tool
    /// result, a retrieved passage or the user's own messages: the same value, a rescaled, converted
    /// or rounded one, one inside a stated "about" or "over", or arithmetic on two of them. After
    /// `stanceGuard`, on the text the user will see.
    ///
    /// It runs only on turns that carried evidence. Without a tool result or a retrieved source, every
    /// figure from the model's general knowledge would come back unbound, and a note on every answer
    /// that mentions a year is noise, not a check. No refusal: an unbound figure may be right. The note
    /// says which figures nothing backs and which contradict a tool, and what to do about it.
    static func bindNumbers(
        _ review: AnswerReview,
        evidence: NumberEvidence,
        trace: inout PipelineTrace
    ) -> AnswerReview {
        guard review.refusal == nil else {
            trace.record(.numberBinding, .skipped(reason: "the answer was withheld, so there are no numbers"))
            return review
        }
        guard !evidence.toolOutputs.isEmpty || !evidence.sources.isEmpty else {
            trace.record(
                .numberBinding,
                .skipped(reason: "no tool result or retrieved source this turn, so nothing to bind to")
            )
            return review
        }
        let report = NumberBinder().bind(answer: review.publishableText, sources: evidence.numberSources)
        guard report.needsAttention, let note = report.note else {
            trace.record(.numberBinding, .noOp(reason: report.summary))
            return review
        }
        trace.record(.numberBinding, .ran(detail: report.summary))
        var flagged = review
        flagged.numberNote = note + " Treat those figures as unchecked, or ask for them to be read back "
            + "from the tool or the source."
        return flagged
    }
}
