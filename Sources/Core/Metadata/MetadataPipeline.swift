import BatchInferenceKit
import EvalHarness
import Foundation
import OutputRepairKit
import SchemaMigrationKit
import StructuredOutputKit

/// What the fan-out produced, before anything has been decoded.
struct MetadataAskAnswers: Sendable {
    /// Ask id → the JSON text that satisfied its contract. Only converged asks appear.
    var texts: [String: String] = [:]
    /// Ask id → what it cost and whether it converged.
    var outcomes: [String: MetadataBatchExecutor.AskOutcome] = [:]
    /// True when the batch refused to run at all, which is distinct from every ask failing.
    var batchFailed = false
}

/// The typed values decoded out of the accepted texts. Either half can be missing.
struct MetadataDrafts: Sendable, Equatable {
    var title: ChatTitleDraft?
    var followUps: ChatFollowUpsDraft?
}

/// A negotiation that came back `.unsupported`.
///
/// `SchemaRegistry.negotiate` throws exactly one error — an unknown contract. An unknown version,
/// a sunset consumer, a missing path and a lossy path all come back as *values*, so a `do/catch`
/// around it silently ignores every refusal it actually produces. This turns the returned refusal
/// into something the same `catch` can classify.
struct MetadataNegotiationRefused: Error, Sendable, Equatable, CustomStringConvertible {
    let summary: String

    var description: String { summary }
}

/// Names a conversation and suggests what to ask next, once a turn has been paid for and shown.
///
/// Runs after the answer is on screen and off the critical path, because none of it is what the
/// user asked for. That placement is also why **nothing here ever produces a `Refusal`**: a
/// refusal in this app is a promise that the user did something they can undo, and there is no
/// such thing for a title nobody requested. When this cannot do its job the conversation gets a
/// fallback title, an empty chip row, and a trace that says exactly which stage gave up and why.
actor MetadataPipeline {
    /// Three attempts, with a real capped backoff.
    ///
    /// Deliberately not `RepairPolicy()`: its default backoff is `.none`, so repair calls fire
    /// back to back against the very endpoint that just struggled, which is the shortest path
    /// from one malformed reply to a self-inflicted 429. Three attempts means the loop sleeps
    /// 400ms and then 800ms — the third delay is never requested — so the worst case adds 1.2s
    /// to a background task nobody is waiting on.
    static let defaultPolicy = RepairPolicy(
        maxAttempts: 3,
        backoff: RepairBackoff(baseMilliseconds: 400, multiplier: 2, capMilliseconds: 2_000)
    )

    /// A cheap model. Naming a conversation is not the work the user is paying for, and putting
    /// it on the same model as the answer doubles the cost of every turn for a nav-bar caption.
    static let defaultModelID = "google/gemini-2.5-flash-lite"

    let asks: [MetadataAsk]
    let concurrency: ConcurrencyLimit
    let completer: any MetadataCompleting
    let loops: [String: OutputRepairLoop<MetadataContract>]
    let contracts: SchemaRegistry
    let decoder: StructuredOutputDecoder
    let recorder: (any BatchEventRecording)?
    /// Where finished turns are kept as golden-case candidates. Nil disables capture entirely.
    let transcripts: (any TranscriptStore)?

    init(
        completer: any MetadataCompleting,
        contracts: SchemaRegistry,
        asks: [MetadataAsk] = MetadataAsk.all,
        policy: RepairPolicy = MetadataPipeline.defaultPolicy,
        sleeper: any RepairSleeper = SystemRepairSleeper(),
        decoder: StructuredOutputDecoder = StructuredOutputDecoder(),
        concurrency: ConcurrencyLimit = ConcurrencyLimit(2),
        recorder: (any BatchEventRecording)? = nil,
        transcripts: (any TranscriptStore)? = InMemoryTranscriptStore()
    ) {
        self.completer = completer
        self.contracts = contracts
        self.asks = asks
        self.decoder = decoder
        self.concurrency = concurrency
        self.recorder = recorder
        self.transcripts = transcripts
        // One loop per ask, held for the life of the pipeline so `RepairStats` accumulate. They
        // can share a dictionary only because `MetadataContract` is one type parameterised by a
        // schema rather than one type per ask — two contract *types* would be two loop types.
        var built: [String: OutputRepairLoop<MetadataContract>] = [:]
        for ask in asks {
            built[ask.id] = OutputRepairLoop(
                contract: ask.contract,
                policy: policy,
                sleeper: sleeper
            )
        }
        self.loops = built
    }

    /// Generates the metadata for one completed turn.
    ///
    /// Returns `nil` only when there was nothing to name. Every other path returns something the
    /// navigation bar can show, because a conversation with no title reads as a conversation that
    /// failed to load.
    func generate(
        userText: String,
        assistantText: String,
        trace: inout PipelineTrace
    ) async -> ChatMetadata? {
        guard !assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            recordNothingToSummarise(trace: &trace)
            return nil
        }
        await capture(userText: userText, assistantText: assistantText, trace: &trace)
        await auditDelaySignal(trace: &trace)
        await auditDelayShape(trace: &trace)
        let answers = await runAsks(userText: userText, assistantText: assistantText, trace: &trace)
        let drafts = await decodeDrafts(answers, trace: &trace)
        return await assemble(drafts, userText: userText, trace: &trace)
    }

    /// Records the finished turn as a golden-case candidate.
    ///
    /// The hard part of an eval suite is not the scoring, it is having real cases to score. This
    /// app is the only thing that sees real prompts against real answers, so it is the only thing
    /// that can produce them — `InMemoryTranscriptStore.snapshotData()` writes the fixture the
    /// suite replays with `ReplayingModel`, and replayed cases cost nothing and cannot flake.
    ///
    /// It lives here, in the pipeline that already runs after the turn is paid for, because
    /// capture must never delay an answer or change what the user sees.
    private func capture(
        userText: String,
        assistantText: String,
        trace: inout PipelineTrace
    ) async {
        guard let transcripts else {
            trace.record(.transcriptCapture, .skipped(reason: "transcript capture is off"))
            return
        }
        // Greedy decoding is asserted rather than described: a transcript recorded under sampling
        // is not reproducible, and a golden case that cannot be reproduced is not golden.
        let decoding = DecodingParameters.deterministic
        let model = ModelDescriptor(
            identifier: MetadataPipeline.defaultModelID,
            build: "live",
            tier: .cloud
        )
        let promptVersion = PromptVersion(templateID: "chat.turn", revision: 1)
        let key = TranscriptKey(
            promptVersion: promptVersion,
            renderedPrompt: userText,
            model: model,
            decoding: decoding
        )
        // Already-seen prompts are left alone. Overwriting would let a later, worse answer quietly
        // replace the recorded one, which is how a regression becomes the baseline.
        if await transcripts.record(for: key) != nil {
            trace.record(.transcriptCapture, .noOp(reason: "this prompt is already recorded"))
            return
        }
        await transcripts.store(
            TranscriptRecord(
                key: key,
                caseID: "chat-\(key.value.prefix(12))",
                promptVersion: promptVersion,
                model: model,
                response: ModelResponse(
                    text: assistantText,
                    inputTokens: 0,
                    outputTokens: 0,
                    latencySeconds: 0,
                    costUSD: 0
                ),
                recordedAt: Date()
            )
        )
        trace.record(.transcriptCapture, .ran(detail: "recorded as a golden-case candidate"))
    }

    /// Every candidate captured so far, for the eval suite to snapshot.
    func capturedTranscripts() async -> [TranscriptRecord] {
        await transcripts?.allRecords() ?? []
    }

    /// Fans the asks out concurrently and records what the fan-out and the repair loops did.
    ///
    /// The `BatchProcessor` is built here rather than stored, and that is a correctness fix
    /// rather than a style choice: `BatchStats` accumulate for a processor's whole lifetime, so a
    /// stored one would report the previous conversation's token total and a `peakActive` that is
    /// a lifetime high-water mark rather than this batch's. The window is enforced per `process`
    /// call too, so a shared processor would let two overlapping sends put double the limit in
    /// flight.
    private func runAsks(
        userText: String,
        assistantText: String,
        trace: inout PipelineTrace
    ) async -> MetadataAskAnswers {
        let executor = MetadataBatchExecutor(asks: asks, loops: loops, completer: completer)
        let processor = BatchProcessor(
            executor: executor,
            limit: concurrency,
            // `.continueOnFailure`, because the whole point of splitting the two asks is that a
            // model failing to name the conversation must not also cost it its chips.
            policy: .continueOnFailure,
            recorder: recorder
        )
        let requests = asks.map {
            BatchRequest(
                id: $0.id,
                prompt: $0.prompt(userText: userText, assistantText: assistantText)
            )
        }
        let started = DispatchTime.now()
        do {
            let report = try await processor.process(requests)
            let answers = MetadataAskAnswers(
                texts: Self.texts(in: report),
                outcomes: await executor.recorded()
            )
            recordBatch(report, asked: requests.count, since: started, trace: &trace)
            recordRepair(answers.outcomes, trace: &trace)
            return answers
        } catch {
            // `BatchError` means this app handed the package something it cannot act on — an
            // empty fan-out, or two asks sharing an id. That is the app breaking, not the model,
            // and its own `description` says which of the two it was.
            trace.record(
                .batchInference,
                .failed(message: "\(error)"),
                durationMs: Self.elapsed(since: started)
            )
            trace.record(.outputRepair, .skipped(reason: "the fan-out never ran"))
            return MetadataAskAnswers(batchFailed: true)
        }
    }

    /// Repair totals for the life of this pipeline — "since launch", never "this conversation".
    /// `RepairStats` is monotonic and `OutputRepairLoop` offers no way to reset it.
    func repairStatistics() async -> [String: RepairStats] {
        var collected: [String: RepairStats] = [:]
        for (id, loop) in loops {
            collected[id] = await loop.stats
        }
        return collected
    }

    func migrationStatistics() async -> MigrationStatistics {
        await contracts.statistics()
    }

    /// Which hops are crossable, in both directions.
    ///
    /// The downgrade direction is the one that serves an older reader, so a chat app that renders
    /// history has to check it too — a gap there is a stored payload nothing can open.
    func contractCoverage() async throws -> MigrationCoverage {
        try await contracts.coverage(of: MetadataSchema.contractID)
    }
}
