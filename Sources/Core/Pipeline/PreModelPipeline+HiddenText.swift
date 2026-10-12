import HiddenTextKit

/// This turn's text and history as the model may read them: invisible runs that are not doing a
/// job in the text are gone.
struct UnhiddenInput: Sendable, Equatable {
    let userText: String
    let history: [ConversationMessage]
}

extension PreModelPipeline {
    /// Removes invisible Unicode a person cannot see and a model reads: Unicode tag characters,
    /// zero-width binary, runs of variation selectors, bidi overrides, stray format characters.
    /// Flags, emoji joiners, Persian and Devanagari joiners and balanced isolates stay.
    ///
    /// First, before the guardrail, because the guardrail's detectors match grapheme clusters and
    /// a zero-width space is a cluster of its own: a card number with one between each group of
    /// four matches nothing until it is gone.
    ///
    /// The history too. Every turn re-sends the history from what the bubbles hold, and a user
    /// bubble holds exactly what was typed or pasted, so a payload cleaned out of this turn's
    /// message would otherwise reach the model again on every turn after it. Assistant entries are
    /// already clean when `hiddenTextOutput` ran on them; a conversation restored from before that
    /// stage existed may not be, which is why they are not exempt.
    ///
    /// No refusal. The user cannot see what is removed and could not act on a banner about it
    /// except by retyping; what was removed, and what it spelled, is in the stage's detail.
    static func removeHiddenText(
        from userText: String,
        history: [ConversationMessage],
        trace: inout PipelineTrace
    ) -> UnhiddenInput {
        let sanitizer = HiddenTextSanitizer()
        let message = sanitizer.sanitize(userText)
        var cleanedHistory: [ConversationMessage] = []
        var historyScalars = 0
        var historyEntries = 0
        for entry in history {
            let cleaned = sanitizer.sanitize(entry.text)
            let removed = cleaned.report.suspiciousScalarCount
            historyScalars += removed
            historyEntries += removed > 0 ? 1 : 0
            cleanedHistory.append(
                ConversationMessage(id: entry.id, role: entry.role, text: cleaned.text, pinned: entry.pinned)
            )
        }
        let removedHere = message.report.suspiciousScalarCount
        guard removedHere + historyScalars > 0 else {
            let kept = message.report.legitimateRuns.count
            let reason = kept == 0
                ? "no invisible characters"
                : "kept \(kept) legitimate invisible run(s), such as an emoji joiner"
            trace.record(.hiddenTextInput, .noOp(reason: reason))
            return UnhiddenInput(userText: userText, history: history)
        }
        var parts: [String] = []
        if removedHere > 0 {
            parts.append("this message: " + HiddenTextDetail.describe(message.report))
        }
        if historyScalars > 0 {
            parts.append("\(historyScalars) hidden scalar(s) from \(historyEntries) earlier message(s)")
        }
        let detail = "removed before the guardrail - " + parts.joined(separator: "; ")
        trace.record(.hiddenTextInput, .ran(detail: detail))
        return UnhiddenInput(userText: message.text, history: cleanedHistory)
    }
}

/// One line for a stage detail: what was removed and, when it decoded, what it spelled.
enum HiddenTextDetail {
    /// Long enough to read an instruction, short enough for a Diagnostics row.
    static let limit = 160

    static func describe(_ report: HiddenTextReport) -> String {
        let summary = HiddenTextFormatter.summary(report)
        guard summary.count > limit else { return summary }
        return String(summary.prefix(limit)) + "..."
    }
}
