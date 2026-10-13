import SessionMaskKit

extension PostModelPipeline {
    /// Turns session tokens in the answer back into the values they stand for, just before the
    /// output guardrail.
    ///
    /// Before it on purpose. The guardrail is still the one place that decides what PII an answer
    /// may show, so a restored address is redacted exactly as it was before this package existed.
    /// After it, the bubble would show the user's own address back to them, and the response cache
    /// would store it under a key built from guardrail-redacted text, where another conversation
    /// whose redacted prompt matched could be served it.
    ///
    /// Restoring at all still matters: without it the bubble, the conversation title, the cache
    /// and the history would carry `[EMAIL_1]`, and the next turn would escape that text as a
    /// literal instead of reading it as the token it was.
    ///
    /// Tokens the model invented or respelled are never guessed at. They stay as written and are
    /// named in the detail.
    func restoreSessionTokens(
        _ answer: String,
        for conversationID: String,
        trace: inout PipelineTrace
    ) async -> String {
        guard let vault = await masks.existingVault(for: conversationID) else {
            trace.record(.sessionRestore, .noOp(reason: "nothing was masked in this conversation"))
            return answer
        }
        let result = await vault.restore(answer)
        guard !result.events.isEmpty else {
            trace.record(.sessionRestore, .noOp(reason: "no session tokens in the answer"))
            return answer
        }
        trace.record(.sessionRestore, .ran(detail: Self.describe(result)))
        return result.text
    }

    static func describe(_ result: RestoreResult) -> String {
        var unknown: [String] = []
        var malformed: [String] = []
        for event in result.events {
            switch event {
            case .restored, .withheld:
                continue
            case let .unknown(text):
                unknown.append(text)
            case let .malformed(text, _):
                malformed.append(text)
            }
        }
        var parts = ["restored \(result.restored.count) token(s) for the output guardrail to screen"]
        if !unknown.isEmpty {
            parts.append("never minted, left as written: " + unknown.joined(separator: " "))
        }
        if !malformed.isEmpty {
            parts.append("respelled, left as written: " + malformed.joined(separator: " "))
        }
        return parts.joined(separator: "; ")
    }
}
