import BatchInferenceKit
import Foundation
import OutputRepairKit
import SchemaMigrationKit
import StructuredOutputKit

// MARK: - Fan-out and repair

extension MetadataPipeline {
    static func texts(in report: BatchReport) -> [String: String] {
        var texts: [String: String] = [:]
        for response in report.responses {
            texts[response.id] = response.text
        }
        return texts
    }

    static func elapsed(since started: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- started.uptimeNanoseconds) / 1_000_000)
    }

    func recordNothingToSummarise(trace: inout PipelineTrace) {
        // All four stages report, rather than going quiet. `PipelineTrace.unreached` is how this
        // app makes a silently dead package visible, and a stage that says nothing is
        // indistinguishable from one that was never wired up.
        let reason = "the turn produced no answer to name"
        trace.record(.batchInference, .skipped(reason: reason))
        trace.record(.outputRepair, .skipped(reason: reason))
        trace.record(.structuredDecode, .skipped(reason: reason))
        trace.record(.schemaMigration, .skipped(reason: reason))
    }

    func recordBatch(
        _ report: BatchReport,
        asked: Int,
        since started: DispatchTime,
        trace: inout PipelineTrace
    ) {
        // Summed from this batch's own responses. `report.stats.usage` is a running total for the
        // processor's whole lifetime, so reading it would bill this conversation for the last one.
        let tokens = report.responses
            .reduce(BatchTokenUsage.zero) { $0 + $1.usage }
            .totalTokens
        var parts = [
            "\(report.responses.count) of \(asked) asks answered",
            "peak \(report.stats.peakActive) in flight (limit \(concurrency.value))",
            "\(tokens) token(s)"
        ]
        // `report.failures` mixes two kinds. A model that actually failed and a request that was
        // never attempted are different facts, and telling a reader the second one refused them
        // is a lie about a call that was never made.
        let failed = report.failures.filter { $0.kind == .executorFailure }
        if !failed.isEmpty {
            parts.append("failed: " + failed.map(\.message).joined(separator: " | "))
        }
        let cancelled = report.failures.filter { $0.kind == .cancelled }
        if !cancelled.isEmpty {
            parts.append("\(cancelled.count) never attempted")
        }
        let detail = parts.joined(separator: " · ")
        // A partial fan-out is the stage working — that is the entire reason for
        // `.continueOnFailure`. Zero answers is not, because there is no product left after it.
        let outcome: StageOutcome = report.responses.isEmpty
            ? .failed(message: detail)
            : .ran(detail: detail)
        trace.record(.batchInference, outcome, durationMs: Self.elapsed(since: started))
    }

    func recordRepair(
        _ outcomes: [String: MetadataBatchExecutor.AskOutcome],
        trace: inout PipelineTrace
    ) {
        let attempted = outcomes.filter { $0.value.attempts > 0 }
        guard !attempted.isEmpty else {
            trace.record(.outputRepair, .skipped(reason: "no ask reached the model"))
            return
        }
        let repaired = attempted.filter { $0.value.attempts > 1 }
        guard !repaired.isEmpty else {
            trace.record(.outputRepair, .noOp(reason: "every ask validated on its first attempt"))
            return
        }
        let detail = repaired
            .sorted { $0.key < $1.key }
            .map { Self.repairSummary(id: $0.key, outcome: $0.value) }
            .joined(separator: " · ")
        // Exhaustion is recorded as `.ran`, not `.failed`. The loop did exactly its job — it
        // bounded what a non-complying model may spend — and the ask it gave up on is already
        // reported by the fan-out. `.failed` here would blame OutputRepairKit for a model that
        // would not answer in the shape it was asked for.
        trace.record(.outputRepair, .ran(detail: detail))
    }

    static func repairSummary(id: String, outcome: MetadataBatchExecutor.AskOutcome) -> String {
        let verdict = outcome.failure == nil ? "repaired" : "exhausted"
        let issues = outcome.issues.isEmpty
            ? ""
            : " — " + outcome.issues.joined(separator: "; ")
        return "\(id): \(outcome.attempts) attempt(s), \(verdict)\(issues)"
    }
}

// MARK: - Typed decoding

extension MetadataPipeline {
    func decodeDrafts(
        _ answers: MetadataAskAnswers,
        trace: inout PipelineTrace
    ) async -> MetadataDrafts {
        guard !answers.texts.isEmpty else {
            let reason = answers.batchFailed
                ? "the fan-out never ran"
                : "no ask produced text to decode"
            trace.record(.structuredDecode, .skipped(reason: reason))
            return MetadataDrafts()
        }
        let (title, titleNote) = await decodeDraft(
            ChatTitleDraft.self, id: MetadataAsk.titleID, texts: answers.texts
        )
        let (followUps, followUpNote) = await decodeDraft(
            ChatFollowUpsDraft.self, id: MetadataAsk.followUpsID, texts: answers.texts
        )
        recordDecode(notes: [titleNote, followUpNote], trace: &trace)
        return MetadataDrafts(title: title, followUps: followUps)
    }

    /// What one draft's decode is worth saying in the trace. Either field, or neither when the
    /// ask produced no text at all.
    struct DecodeNote: Sendable, Equatable {
        var succeeded: String?
        var failed: String?
    }

    private func recordDecode(notes: [DecodeNote], trace: inout PipelineTrace) {
        let broke = notes.compactMap(\.failed)
        guard broke.isEmpty else {
            // The repair loop already proved this text satisfies the schema, so a `Decodable`
            // failure afterwards is not the model's mistake: it means the Swift type and the
            // schema it publishes have drifted apart. That is this app's bug and nobody else's.
            trace.record(.structuredDecode, .failed(message: broke.joined(separator: " | ")))
            return
        }
        let decoded = notes.compactMap(\.succeeded)
        guard !decoded.isEmpty else {
            trace.record(
                .structuredDecode,
                .noOp(reason: "no ask this pipeline knows how to decode produced text")
            )
            return
        }
        trace.record(.structuredDecode, .ran(detail: decoded.joined(separator: ", ")))
    }

    private func decodeDraft<T: Decodable & JSONSchemaConvertible & Sendable>(
        _ type: T.Type,
        id: String,
        texts: [String: String]
    ) async -> (T?, DecodeNote) {
        guard let text = texts[id] else { return (nil, DecodeNote()) }
        do {
            let value = try await decoder.decode(type, from: text)
            return (value, DecodeNote(succeeded: "\(id) → \(T.self)"))
        } catch {
            return (nil, DecodeNote(failed: "\(id): \(error)"))
        }
    }
}

// MARK: - Versioning

extension MetadataPipeline {
    func assemble(
        _ drafts: MetadataDrafts,
        userText: String,
        trace: inout PipelineTrace
    ) async -> ChatMetadata? {
        let suggestions = drafts.followUps?.followUps ?? []
        guard let title = drafts.title?.title else {
            // Nothing to migrate. The fallback title is the app's own text, written at v2
            // directly, so there is no v1 payload to carry forward — and recording a migration
            // that did not happen is the one thing a trace must never do.
            trace.record(
                .schemaMigration,
                .noOp(reason: "the fallback title is written at v2; there is no v1 payload")
            )
            return ChatMetadata.fallback(userText: userText, followUps: suggestions)
        }
        let started = DispatchTime.now()
        do {
            let upgraded = try await upgrade(
                MetadataSchema.payload(title: title, followUps: suggestions)
            )
            trace.record(
                .schemaMigration,
                .ran(detail: upgraded.detail),
                durationMs: Self.elapsed(since: started)
            )
            return upgraded.metadata
        } catch {
            // `MigrationError` deliberately has no `LocalizedError` conformance, so
            // `localizedDescription` would return Foundation boilerplate rather than the reason.
            // Interpolation gives the readable reflection form the package intends.
            trace.record(
                .schemaMigration,
                .failed(message: "\(error)"),
                durationMs: Self.elapsed(since: started)
            )
            // The model's title is still a good title, so it is shown — with `.model`, which is
            // what the hop would have stamped. What was lost is the checking, not the value, and
            // the trace above is where that loss is recorded.
            return ChatMetadata(title: title, followUps: suggestions, titleSource: .model)
        }
    }

    /// Carries a v1 payload the model produced up to the v2 shape the app renders.
    private func upgrade(
        _ payload: [String: FieldValue]
    ) async throws -> (metadata: ChatMetadata, detail: String) {
        let planned = try await negotiated()
        let result = try await contracts.migrate(
            payload,
            of: MetadataSchema.contractID,
            from: MetadataSchema.producerVersion,
            to: MetadataSchema.consumerVersion,
            at: MetadataSchema.epoch
        )
        let verdict = try await contracts.compatibility(
            of: MetadataSchema.contractID,
            from: MetadataSchema.producerVersion,
            to: MetadataSchema.consumerVersion
        )
        // Back through JSON on purpose. `FieldValue` is not `Codable`, so an adapter is required
        // either way, and going via text means the migrated payload is checked against
        // `ChatMetadata.jsonSchema` and `Decodable` before it reaches a view.
        let metadata = try await decoder.decode(
            ChatMetadata.self,
            from: try MetadataPayload.text(result.payload)
        )
        let detail = "\(planned) · \(result.appliedSteps) step(s) applied "
            + "· \(verdict.changes.count) breaking change(s) "
            + "· titleSource=\(metadata.titleSource.rawValue)"
        return (metadata, detail)
    }

    private func negotiated() async throws -> MigrationPath {
        let outcome = try await contracts.negotiate(
            MetadataSchema.contractID,
            producerVersion: MetadataSchema.producerVersion,
            consumerVersion: MetadataSchema.consumerVersion,
            at: MetadataSchema.epoch
        )
        guard case let .migrate(path) = outcome else {
            throw MetadataNegotiationRefused(summary: "\(outcome)")
        }
        return path
    }
}
