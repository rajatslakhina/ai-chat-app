import SwiftUI

/// What the twenty-five packages did to the last message.
struct DiagnosticsView: View {
    @Environment(ChatViewModel.self) private var model

    private var trace: PipelineTrace { model.trace }

    var body: some View {
        List {
            SummarySection(summary: DiagnosticsReport.summary(for: trace))
            ForEach(DiagnosticsReport.sections(for: trace)) { section in
                Section {
                    ForEach(Array(section.records.enumerated()), id: \.offset) { _, record in
                        StageRecordRow(record: record)
                    }
                } header: {
                    header(for: section.stage)
                }
            }
            unreached
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("diagnosticsList")
    }

    private func header(for stage: PipelineStage) -> some View {
        HStack {
            Text(stage.title)
            Spacer()
            Text(stage.package)
                .font(Theme.Typeface.metric)
                .foregroundStyle(.tertiary)
                .textCase(nil)
        }
    }

    /// The stages nothing reported against.
    ///
    /// Its own section rather than an omission, which is the entire reason `PipelineTrace.unreached`
    /// exists: a package that quietly did nothing looks exactly like a package that was never wired
    /// in, and the only way to tell them apart from the outside is to name the ones that never
    /// spoke. Before the first send that is all of them, and saying so is more useful than an empty
    /// screen.
    @ViewBuilder
    private var unreached: some View {
        let missing = trace.unreached
        if missing.isEmpty {
            Section {
                Label("Every stage reported.", systemImage: "checkmark.seal")
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.success)
                    .accessibilityIdentifier("unreachedNone")
            }
        } else {
            Section {
                ForEach(missing) { stage in
                    UnreachedRow(stage: stage)
                }
            } header: {
                Text("Never reached (\(missing.count))")
            } footer: {
                Text(
                    trace.records.isEmpty
                        ? "No message has been sent yet, so nothing has run. Every stage the "
                            + "pipeline declares is listed here."
                        : "These stages did not report on the last message. A stage that ran and "
                            + "chose to do nothing records a no-op instead, so anything in this "
                            + "list genuinely never executed."
                )
            }
        }
    }
}

/// The counts, so the shape of a run is readable before any single row is.
struct SummarySection: View {
    let summary: DiagnosticsReport.Summary

    var body: some View {
        Section {
            HStack(spacing: Theme.Spacing.tight) {
                MetricChip("\(summary.ran) ran", tint: Theme.Palette.success)
                MetricChip("\(summary.noOp) no-op", tint: Theme.Palette.neutral)
                MetricChip("\(summary.skipped) skipped", tint: Theme.Palette.informational)
            }
            HStack(spacing: Theme.Spacing.tight) {
                MetricChip("\(summary.refused) refused", tint: Theme.Palette.refusal)
                MetricChip("\(summary.failed) failed", tint: Theme.Palette.failure)
                MetricChip("\(summary.unreached) unreached", tint: Theme.Palette.neutral)
            }
            LabeledContent("Measured", value: "\(summary.totalDurationMs) ms")
                .accessibilityIdentifier("diagnosticsDuration")
        } header: {
            Text("Last message")
        } footer: {
            Text(
                "\(summary.accountedFor) of \(PipelineStage.allCases.count) declared stages "
                    + "accounted for. Durations are measured during the send, not reconstructed "
                    + "afterwards."
            )
        }
    }
}

/// One recorded outcome.
struct StageRecordRow: View {
    let record: StageRecord

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.snug) {
            Image(systemName: record.outcome.diagnosticsIcon)
                .foregroundStyle(record.outcome.diagnosticsTint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.hair) {
                Text(record.outcome.diagnosticsLabel)
                    .font(Theme.Typeface.heading)
                    .foregroundStyle(record.outcome.diagnosticsTint)
                Text(record.outcome.summary)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Text("\(record.durationMs) ms")
                .font(Theme.Typeface.metric)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("stageRow-\(record.stage.rawValue)")
    }
}

/// A stage that never reported.
struct UnreachedRow: View {
    let stage: PipelineStage

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: Theme.Spacing.hair) {
                Text(stage.title).font(Theme.Typeface.body)
                Text(stage.package)
                    .font(Theme.Typeface.metric)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Image(systemName: "questionmark.circle")
                .foregroundStyle(Theme.Palette.neutral)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("unreachedStage-\(stage.rawValue)")
    }
}
