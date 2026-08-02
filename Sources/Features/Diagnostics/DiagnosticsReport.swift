import Foundation
import SwiftUI

/// One stage and everything the last send recorded against it.
///
/// A list of records rather than a single one because `PipelineTrace` does not promise uniqueness
/// — `PipelineTrace.outcome(for:)` returns the *first* match, which is only meaningful if a second
/// can exist. Collapsing to one here would silently hide the extra, which is the exact failure this
/// screen exists to prevent.
struct DiagnosticsSection: Identifiable, Equatable {
    let stage: PipelineStage
    let records: [StageRecord]

    var id: String { stage.rawValue }
}

/// Turns a trace into what Diagnostics renders.
///
/// Pure and separate from the view on purpose: the interesting claims — every stage appears
/// exactly once across the screen, an untouched stage lands in `unreached` rather than nowhere —
/// are assertions, and a `body` cannot be asserted on.
enum DiagnosticsReport {
    /// Counts by outcome, plus the stages that never reported.
    struct Summary: Equatable {
        var ran = 0
        var noOp = 0
        var skipped = 0
        var refused = 0
        var failed = 0
        var unreached = 0
        var totalDurationMs = 0

        /// Every stage accounted for exactly once. A screen claiming to enumerate the pipeline has
        /// to add up, and this is the arithmetic that says so.
        var accountedFor: Int { ran + noOp + skipped + refused + failed + unreached }
    }

    /// The stages that reported, in pipeline order rather than the order they happened to record.
    ///
    /// Declaration order *is* the architecture — it is why `PipelineStage` is written the way it
    /// is — so a reader comparing this screen against the pipeline diagram finds the same sequence.
    static func sections(for trace: PipelineTrace) -> [DiagnosticsSection] {
        PipelineStage.allCases.compactMap { stage in
            let records = trace.records.filter { $0.stage == stage }
            guard !records.isEmpty else { return nil }
            return DiagnosticsSection(stage: stage, records: records)
        }
    }

    static func summary(for trace: PipelineTrace) -> Summary {
        var summary = Summary()
        for record in trace.records {
            switch record.outcome {
            case .ran: summary.ran += 1
            case .noOp: summary.noOp += 1
            case .skipped: summary.skipped += 1
            case .refused: summary.refused += 1
            case .failed: summary.failed += 1
            }
        }
        summary.unreached = trace.unreached.count
        summary.totalDurationMs = trace.totalDurationMs
        return summary
    }
}

extension StageOutcome {
    /// The one-word verdict shown next to a stage.
    ///
    /// "Refused" and "Failed" stay separate words all the way to the pixel. A refusal is the system
    /// working — a budget saying no, a guardrail redacting — and a failure is the system breaking;
    /// a screen that painted both red would undo the distinction the whole type exists to keep.
    var diagnosticsLabel: String {
        switch self {
        case .ran: return "Ran"
        case .noOp: return "No-op"
        case .skipped: return "Skipped"
        case .refused: return "Refused"
        case .failed: return "Failed"
        }
    }

    var diagnosticsTint: Color {
        switch self {
        case .ran: return Theme.Palette.success
        case .noOp: return Theme.Palette.neutral
        case .skipped: return Theme.Palette.informational
        case .refused: return Theme.Palette.refusal
        case .failed: return Theme.Palette.failure
        }
    }

    var diagnosticsIcon: String {
        switch self {
        case .ran: return "checkmark.circle.fill"
        case .noOp: return "circle.dashed"
        case .skipped: return "minus.circle"
        case .refused: return "hand.raised.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }
}
