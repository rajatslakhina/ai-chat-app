import BatchInferenceKit
import Foundation
import OutputRepairKit
import SchemaMigrationKit
import StructuredOutputKit
import Testing
@testable import AIChatApp

// MARK: - Harness

/// Hands back a scripted sequence of replies per ask.
///
/// Scripted at the `MetadataCompleting` seam rather than at HTTP, because every interesting case
/// in this feature is a *sequence* — a malformed reply followed by a good one is the whole reason
/// the repair loop exists — and expressing that in canned HTTP bodies would test `URLProtocol`.
actor ScriptedCompleter: MetadataCompleting {
    enum Step: Sendable {
        case reply(String)
        case fail(String)
        case cancel
    }

    private var scripts: [String: [Step]]
    private let tokensPerReply: Int
    private let holdNanoseconds: UInt64
    private var inFlight = 0
    private(set) var calls: [String] = []
    /// The most calls this completer ever had open at once — an independent second opinion on
    /// what `BatchStats.peakActive` reports.
    private(set) var peakInFlight = 0

    init(
        title: [Step],
        followUps: [Step],
        tokensPerReply: Int = 10,
        holdNanoseconds: UInt64 = 0
    ) {
        self.scripts = [MetadataAsk.titleID: title, MetadataAsk.followUpsID: followUps]
        self.tokensPerReply = tokensPerReply
        self.holdNanoseconds = holdNanoseconds
    }

    static func askID(for system: String) -> String {
        system == MetadataAsk.followUps.system ? MetadataAsk.followUpsID : MetadataAsk.titleID
    }

    func complete(system: String, user: String) async throws -> MetadataCompletion {
        let id = Self.askID(for: system)
        calls.append(id)
        inFlight += 1
        peakInFlight = max(peakInFlight, inFlight)
        defer { inFlight -= 1 }
        if holdNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: holdNanoseconds)
        }
        switch next(for: id) {
        case let .reply(text):
            return MetadataCompletion(
                text: text,
                promptTokens: tokensPerReply,
                completionTokens: tokensPerReply
            )
        case let .fail(message):
            throw MetadataProviderFailure(summary: message)
        case .cancel:
            throw CancellationError()
        }
    }

    /// Serves the next step, then repeats the last one — so a one-step script answers every
    /// repair attempt identically, which is exactly how a budget gets exhausted.
    private func next(for id: String) -> Step {
        guard var steps = scripts[id], let step = steps.first else {
            return .fail("no script for \(id)")
        }
        steps.removeFirst()
        scripts[id] = steps.isEmpty ? [step] : steps
        return step
    }
}

/// A sleeper that records what it was asked for instead of sleeping.
actor RecordingSleeper: RepairSleeper {
    private(set) var requested: [Int] = []

    func sleep(milliseconds: Int) async throws {
        requested.append(milliseconds)
    }
}

enum MetadataHarness {
    static let goodTitle = ScriptedCompleter.Step.reply(MetadataFixtures.titleJSON)
    static let goodFollowUps = ScriptedCompleter.Step.reply(MetadataFixtures.followUpsJSON)

    static func pipeline(
        completer: any MetadataCompleting,
        contracts: SchemaRegistry? = nil,
        asks: [MetadataAsk] = MetadataAsk.all,
        policy: RepairPolicy = RepairPolicy(maxAttempts: 3, backoff: .none),
        sleeper: any RepairSleeper = RecordingSleeper(),
        recorder: (any BatchEventRecording)? = nil
    ) async throws -> MetadataPipeline {
        let registry: SchemaRegistry
        if let contracts {
            registry = contracts
        } else {
            registry = try await MetadataSchema.makeRegistry()
        }
        return MetadataPipeline(
            completer: completer,
            contracts: registry,
            asks: asks,
            policy: policy,
            sleeper: sleeper,
            recorder: recorder
        )
    }

    static func generate(
        _ pipeline: MetadataPipeline,
        userText: String = "what is the capital of France",
        assistantText: String = "Paris is the capital of France."
    ) async -> (metadata: ChatMetadata?, trace: PipelineTrace) {
        var trace = PipelineTrace()
        let metadata = await pipeline.generate(
            userText: userText,
            assistantText: assistantText,
            trace: &trace
        )
        return (metadata, trace)
    }

    static func summary(_ trace: PipelineTrace, _ stage: PipelineStage) -> String {
        trace.outcome(for: stage)?.summary ?? "<never recorded>"
    }
}

// MARK: - The happy path

@Suite("Metadata pipeline — a turn that names itself")
struct MetadataHappyPathTests {
    @Test("all four stages report, and the metadata comes back typed")
    func everyStageReports() async throws {
        let completer = ScriptedCompleter(
            title: [MetadataHarness.goodTitle],
            followUps: [MetadataHarness.goodFollowUps]
        )
        let pipeline = try await MetadataHarness.pipeline(completer: completer)

        let (metadata, trace) = await MetadataHarness.generate(pipeline)

        let result = try #require(metadata)
        #expect(result.title == "Capital of France")
        #expect(result.followUps == ["What is the population?", "When was it founded?"])
        #expect(result.titleSource == .model)

        for stage in [PipelineStage.batchInference, .outputRepair, .structuredDecode, .schemaMigration] {
            #expect(trace.outcome(for: stage) != nil, "\(stage.rawValue) never reported")
        }
        #expect(MetadataHarness.summary(trace, .batchInference).contains("2 of 2 asks answered"))
        #expect(MetadataHarness.summary(trace, .outputRepair).contains("first attempt"))
        #expect(MetadataHarness.summary(trace, .structuredDecode).contains("ChatTitleDraft"))
        #expect(MetadataHarness.summary(trace, .schemaMigration).contains("v1 -> v2"))
    }

    /// The figure the package measures at admission, not one this app estimates afterwards.
    @Test("the fan-out reports the real peak in flight, and both calls really do overlap")
    func peakInFlightIsReal() async throws {
        let completer = ScriptedCompleter(
            title: [MetadataHarness.goodTitle],
            followUps: [MetadataHarness.goodFollowUps],
            holdNanoseconds: 30_000_000
        )
        let pipeline = try await MetadataHarness.pipeline(completer: completer)

        let (_, trace) = await MetadataHarness.generate(pipeline)

        #expect(MetadataHarness.summary(trace, .batchInference).contains("peak 2 in flight (limit 2)"))
        #expect(await completer.peakInFlight == 2, "the two asks were run one after the other")
    }

    @Test("the reported token total is this batch's, not the processor's lifetime")
    func tokensArePerBatch() async throws {
        let completer = ScriptedCompleter(
            title: [MetadataHarness.goodTitle],
            followUps: [MetadataHarness.goodFollowUps]
        )
        let pipeline = try await MetadataHarness.pipeline(completer: completer)

        let (_, first) = await MetadataHarness.generate(pipeline)
        let (_, second) = await MetadataHarness.generate(pipeline, userText: "and Spain?")

        #expect(MetadataHarness.summary(first, .batchInference).contains("40 token(s)"))
        #expect(
            MetadataHarness.summary(second, .batchInference).contains("40 token(s)"),
            "a lifetime total would have doubled here"
        )
    }

    @Test("the migration detail names the hop, the step count and the breaking change")
    func migrationDetail() async throws {
        let completer = ScriptedCompleter(
            title: [MetadataHarness.goodTitle],
            followUps: [MetadataHarness.goodFollowUps]
        )
        let pipeline = try await MetadataHarness.pipeline(completer: completer)

        let (_, trace) = await MetadataHarness.generate(pipeline)
        let detail = MetadataHarness.summary(trace, .schemaMigration)
        #expect(detail.contains("1 step(s) applied"))
        #expect(detail.contains("1 breaking change(s)"))
        #expect(detail.contains("titleSource=model"))
    }

    @Test("a fenced reply is unwrapped rather than costing a repair round")
    func fencedRepliesCostNothing() async throws {
        let completer = ScriptedCompleter(
            title: [.reply(MetadataFixtures.fencedTitle)],
            followUps: [MetadataHarness.goodFollowUps]
        )
        let pipeline = try await MetadataHarness.pipeline(completer: completer)

        let (metadata, trace) = await MetadataHarness.generate(pipeline)
        #expect(metadata?.title == "Capital of France")
        #expect(MetadataHarness.summary(trace, .outputRepair).contains("first attempt"))
        #expect(await completer.calls.count == 2, "one call per ask")
    }

    @Test("statistics are exposed for diagnostics, labelled as lifetime totals")
    func statistics() async throws {
        let completer = ScriptedCompleter(
            title: [MetadataHarness.goodTitle],
            followUps: [MetadataHarness.goodFollowUps]
        )
        let pipeline = try await MetadataHarness.pipeline(completer: completer)
        _ = await MetadataHarness.generate(pipeline)
        _ = await MetadataHarness.generate(pipeline, userText: "and Spain?")

        let repair = await pipeline.repairStatistics()
        #expect(repair[MetadataAsk.titleID]?.totalRuns == 2)
        #expect(repair[MetadataAsk.titleID]?.succeeded == 2)
        #expect(repair[MetadataAsk.followUpsID]?.exhausted == 0)

        let migrations = await pipeline.migrationStatistics()
        #expect(migrations.migrations == 2)
        #expect(migrations.refusals == 0)

        let coverage = try await pipeline.contractCoverage()
        #expect(coverage.canUpgradeThroughout)
        #expect(coverage.canDowngradeThroughout)
    }
}

// MARK: - Repair

@Suite("Metadata pipeline — repairing a malformed reply")
struct MetadataRepairTests {
    @Test("a malformed first reply is repaired rather than losing the feature")
    func repairsAndRecovers() async throws {
        let completer = ScriptedCompleter(
            title: [.reply("I think I'd call it Paris"), MetadataHarness.goodTitle],
            followUps: [MetadataHarness.goodFollowUps]
        )
        let pipeline = try await MetadataHarness.pipeline(completer: completer)

        let (metadata, trace) = await MetadataHarness.generate(pipeline)

        #expect(metadata?.title == "Capital of France")
        #expect(metadata?.titleSource == .model)
        let detail = MetadataHarness.summary(trace, .outputRepair)
        #expect(detail.contains("2 attempt(s), repaired"))
        #expect(detail.contains("did not contain a JSON object"))
        // Counted rather than compared as a sequence. The two asks are fanned out concurrently at
        // `ConcurrencyLimit(2)`, so which of them reaches the completer first is a scheduling
        // outcome, not a property of the pipeline — asserting the interleaving made this test fail
        // roughly one run in three under load. What the repair loop actually promises is that the
        // title was asked twice and the follow-ups exactly once, which is what is asserted here.
        let calls = await completer.calls
        #expect(calls.count == 3)
        #expect(calls.filter { $0 == MetadataAsk.titleID }.count == 2)
        #expect(calls.filter { $0 == MetadataAsk.followUpsID }.count == 1)
        #expect(calls.last == MetadataAsk.titleID, "the repair is the last call made")
    }

    /// The structured feedback is the point: the repair prompt has to say what was wrong.
    @Test("the issue fed back names the rule that was broken")
    func feedbackIsStructured() async throws {
        let long = MetadataFixtures.title(String(repeating: "n", count: 90))
        let completer = ScriptedCompleter(
            title: [.reply(long), MetadataHarness.goodTitle],
            followUps: [MetadataHarness.goodFollowUps]
        )
        let pipeline = try await MetadataHarness.pipeline(completer: completer)

        let (_, trace) = await MetadataHarness.generate(pipeline)
        let detail = MetadataHarness.summary(trace, .outputRepair)
        #expect(detail.contains("expected at most 48 characters"))
        #expect(detail.contains("observed 90 characters"))
    }

    @Test("a model that never complies exhausts its budget and the app falls back")
    func exhausts() async throws {
        let completer = ScriptedCompleter(
            title: [.reply("no json here, ever")],
            followUps: [MetadataHarness.goodFollowUps]
        )
        let pipeline = try await MetadataHarness.pipeline(completer: completer)

        let (metadata, trace) = await MetadataHarness.generate(pipeline)

        let result = try #require(metadata)
        #expect(result.title == "what is the capital of France")
        #expect(result.titleSource == .fallback, "the app must not claim a model wrote this")
        #expect(result.followUps == ["What is the population?", "When was it founded?"])

        #expect(MetadataHarness.summary(trace, .batchInference).contains("1 of 2 asks answered"))
        #expect(MetadataHarness.summary(trace, .outputRepair).contains("3 attempt(s), exhausted"))
        // The loop bounded a non-complying model, which is the loop working, not breaking.
        #expect(trace.outcome(for: .outputRepair)?.isFailure == false)
        #expect(MetadataHarness.summary(trace, .schemaMigration).contains("no v1 payload"))
        #expect(await completer.calls.filter { $0 == MetadataAsk.titleID }.count == 3)
    }

    @Test("when both asks need repairing, both are reported, in a stable order")
    func repairsAreReportedInOrder() async throws {
        let completer = ScriptedCompleter(
            title: [.reply("prose"), MetadataHarness.goodTitle],
            followUps: [.reply(MetadataFixtures.followUps(["only one"])), MetadataHarness.goodFollowUps]
        )
        let pipeline = try await MetadataHarness.pipeline(completer: completer)

        let (metadata, trace) = await MetadataHarness.generate(pipeline)

        #expect(metadata?.title == "Capital of France")
        #expect(metadata?.followUps.count == 2)
        let detail = MetadataHarness.summary(trace, .outputRepair)
        let followUpsAt = try #require(detail.range(of: MetadataAsk.followUpsID))
        let titleAt = try #require(detail.range(of: MetadataAsk.titleID))
        #expect(followUpsAt.lowerBound < titleAt.lowerBound, "sorted by id, not by completion order")
        #expect(detail.contains("2 to 3 items"))
    }

    /// A repair round with nothing to say about it should still render one clean line rather than
    /// a dangling separator.
    @Test("a repaired ask with no recorded issue still summarises cleanly")
    func repairSummaryWithoutIssues() {
        let summary = MetadataPipeline.repairSummary(
            id: "chat.metadata.title",
            outcome: MetadataBatchExecutor.AskOutcome(attempts: 2, issues: [], failure: nil)
        )
        #expect(summary == "chat.metadata.title: 2 attempt(s), repaired")
    }

    /// `RepairPolicy()`'s own default backoff is `.none`, which fires repairs back to back at the
    /// endpoint that just struggled. This app does not accept that default.
    @Test("the shipped policy backs off between repairs on a real, capped schedule")
    func shippedPolicyBacksOff() async throws {
        let sleeper = RecordingSleeper()
        let completer = ScriptedCompleter(
            title: [.reply("nope"), .reply("still nope"), MetadataHarness.goodTitle],
            followUps: [MetadataHarness.goodFollowUps]
        )
        let pipeline = try await MetadataHarness.pipeline(
            completer: completer,
            policy: MetadataPipeline.defaultPolicy,
            sleeper: sleeper
        )

        let (metadata, _) = await MetadataHarness.generate(pipeline)
        #expect(metadata?.title == "Capital of France")
        #expect(await sleeper.requested == [400, 800], "the third delay is never requested")
        #expect(MetadataPipeline.defaultPolicy.backoff.capMilliseconds == 2_000)
    }
}

// MARK: - Failure

@Suite("Metadata pipeline — when it cannot do its job")
struct MetadataFailureTests {
    @Test("a transport failure on one ask leaves the other one alone")
    func oneAskFails() async throws {
        let completer = ScriptedCompleter(
            title: [MetadataHarness.goodTitle],
            followUps: [.fail("rate limited by OpenRouter")]
        )
        let pipeline = try await MetadataHarness.pipeline(completer: completer)

        let (metadata, trace) = await MetadataHarness.generate(pipeline)

        #expect(metadata?.title == "Capital of France")
        #expect(metadata?.titleSource == .model)
        #expect(metadata?.followUps.isEmpty == true, "no chips rather than wrong chips")
        let detail = MetadataHarness.summary(trace, .batchInference)
        #expect(detail.contains("1 of 2 asks answered"))
        #expect(detail.contains("rate limited by OpenRouter"))
    }

    /// The loop aborts on a producer throw no matter how much attempt budget is left, so a
    /// transport failure must not read as three wasted calls.
    @Test("a transport failure is not retried by the repair loop")
    func transportFailureIsNotRetried() async throws {
        let completer = ScriptedCompleter(
            title: [.fail("could not reach OpenRouter: offline")],
            followUps: [MetadataHarness.goodFollowUps]
        )
        let pipeline = try await MetadataHarness.pipeline(completer: completer)

        _ = await MetadataHarness.generate(pipeline)
        #expect(await completer.calls.filter { $0 == MetadataAsk.titleID }.count == 1)
    }

    @Test("both asks failing is recorded as a failure, and still leaves a usable title")
    func bothAsksFail() async throws {
        let completer = ScriptedCompleter(
            title: [.fail("offline")],
            followUps: [.fail("offline")]
        )
        let pipeline = try await MetadataHarness.pipeline(completer: completer)

        let (metadata, trace) = await MetadataHarness.generate(pipeline)

        #expect(metadata?.titleSource == .fallback)
        #expect(metadata?.title == "what is the capital of France")
        #expect(trace.outcome(for: .batchInference)?.isFailure == true)
        #expect(MetadataHarness.summary(trace, .batchInference).contains("0 of 2 asks answered"))
        #expect(MetadataHarness.summary(trace, .structuredDecode).contains("no ask produced text"))
    }

    @Test("a turn with no answer to name skips all four stages rather than going quiet")
    func nothingToName() async throws {
        let completer = ScriptedCompleter(title: [MetadataHarness.goodTitle], followUps: [])
        let pipeline = try await MetadataHarness.pipeline(completer: completer)

        var trace = PipelineTrace()
        let metadata = await pipeline.generate(userText: "hi", assistantText: "   ", trace: &trace)

        #expect(metadata == nil)
        for stage in [PipelineStage.batchInference, .outputRepair, .structuredDecode, .schemaMigration] {
            #expect(trace.outcome(for: stage) == .skipped(reason: "the turn produced no answer to name"))
        }
        #expect(await completer.calls.isEmpty, "nothing was spent")
    }

    /// A duplicate id makes a report ambiguous, and the package refuses the whole batch for it.
    /// That is this app handing the package something wrong, so it is a failure, not a refusal.
    @Test("two asks sharing an id fail the fan-out with the package's own words")
    func duplicateAskIDs() async throws {
        let completer = ScriptedCompleter(title: [MetadataHarness.goodTitle], followUps: [])
        let pipeline = try await MetadataHarness.pipeline(
            completer: completer,
            asks: [MetadataAsk.title, MetadataAsk.title]
        )

        let (metadata, trace) = await MetadataHarness.generate(pipeline)

        #expect(metadata?.titleSource == .fallback)
        #expect(MetadataHarness.summary(trace, .batchInference).contains("Duplicate request id"))
        #expect(trace.outcome(for: .outputRepair) == .skipped(reason: "the fan-out never ran"))
        #expect(MetadataHarness.summary(trace, .structuredDecode).contains("the fan-out never ran"))
        #expect(await completer.calls.isEmpty)
    }

    @Test("a pipeline configured with no asks at all fails rather than reporting success")
    func noAsks() async throws {
        let completer = ScriptedCompleter(title: [], followUps: [])
        let pipeline = try await MetadataHarness.pipeline(completer: completer, asks: [])

        let (metadata, trace) = await MetadataHarness.generate(pipeline)
        #expect(metadata?.titleSource == .fallback)
        #expect(MetadataHarness.summary(trace, .batchInference).contains("batch was empty"))
    }

    /// The one case where a good model title survives a broken app: the value is kept, the
    /// checking is not, and the trace is where that loss is recorded.
    @Test("a registry that never bootstrapped fails the migration and keeps the title")
    func brokenRegistry() async throws {
        let completer = ScriptedCompleter(
            title: [MetadataHarness.goodTitle],
            followUps: [MetadataHarness.goodFollowUps]
        )
        let pipeline = try await MetadataHarness.pipeline(
            completer: completer,
            contracts: SchemaRegistry()
        )

        let (metadata, trace) = await MetadataHarness.generate(pipeline)

        #expect(metadata?.title == "Capital of France")
        #expect(metadata?.titleSource == .model)
        #expect(trace.outcome(for: .schemaMigration)?.isFailure == true)
        #expect(MetadataHarness.summary(trace, .schemaMigration).contains("unknownContract"))
    }

    /// The repair loop proves the text satisfies the *schema*. If the Swift type it is then
    /// decoded into has drifted away from that schema, nothing else in the system will notice —
    /// so this stage has to say so rather than quietly producing no title.
    @Test("a schema that has drifted from its Swift type is reported as this app's bug")
    func schemaAndTypeDrift() async throws {
        // A title ask wired to the follow-ups contract: the reply validates, and then fails to
        // decode as `ChatTitleDraft` because it has no `title` at all.
        let drifted = MetadataAsk(
            id: MetadataAsk.titleID,
            system: MetadataAsk.title.system,
            contract: MetadataAsk.followUps.contract,
            instruction: MetadataAsk.title.instruction
        )
        let completer = ScriptedCompleter(
            title: [MetadataHarness.goodFollowUps],
            followUps: []
        )
        let pipeline = try await MetadataHarness.pipeline(completer: completer, asks: [drifted])

        let (metadata, trace) = await MetadataHarness.generate(pipeline)

        #expect(trace.outcome(for: .structuredDecode)?.isFailure == true)
        #expect(MetadataHarness.summary(trace, .structuredDecode).contains(MetadataAsk.titleID))
        #expect(metadata?.titleSource == .fallback, "the user still gets a usable title")
        #expect(trace.refusal == nil)
    }

    /// A registry whose contract is registered but whose hop is not. `negotiate` reports this as
    /// a *value*, so a `do/catch` alone would let it through as if the versions agreed.
    @Test("a missing migration step is caught as a negotiation refusal, not ignored")
    func missingMigrationStep() async throws {
        let incomplete = SchemaRegistry()
        try await incomplete.register(MetadataSchema.definition)

        let completer = ScriptedCompleter(
            title: [MetadataHarness.goodTitle],
            followUps: [MetadataHarness.goodFollowUps]
        )
        let pipeline = try await MetadataHarness.pipeline(completer: completer, contracts: incomplete)

        let (metadata, trace) = await MetadataHarness.generate(pipeline)

        #expect(trace.outcome(for: .schemaMigration)?.isFailure == true)
        let detail = MetadataHarness.summary(trace, .schemaMigration)
        #expect(detail.contains("no migration path"))
        #expect(metadata?.title == "Capital of France", "a config gap must not cost a good title")

        let coverage = try await pipeline.contractCoverage()
        #expect(!coverage.canUpgradeThroughout, "the gap is visible at launch, before a user hits it")
        #expect(coverage.upgradeGaps.map(\.description) == ["v1 -> v2"])
    }

    @Test("an ask this pipeline cannot decode reports a no-op rather than an empty success")
    func unrecognisedAsk() async throws {
        let custom = MetadataAsk(
            id: "chat.metadata.custom",
            system: MetadataAsk.title.system,
            contract: MetadataAsk.title.contract,
            instruction: MetadataAsk.title.instruction
        )
        let completer = ScriptedCompleter(title: [MetadataHarness.goodTitle], followUps: [])
        let pipeline = try await MetadataHarness.pipeline(completer: completer, asks: [custom])

        let (metadata, trace) = await MetadataHarness.generate(pipeline)
        #expect(metadata?.titleSource == .fallback)
        #expect(MetadataHarness.summary(trace, .structuredDecode).contains("no ask this pipeline"))
    }

    /// The doctrine this whole app is built on: a refusal is a promise the user can act, and
    /// there is nothing for them to act on in a caption they never asked for.
    @Test("no path through metadata generation ever produces a refusal")
    func neverRefuses() async throws {
        let scripts: [(title: [ScriptedCompleter.Step], followUps: [ScriptedCompleter.Step])] = [
            ([MetadataHarness.goodTitle], [MetadataHarness.goodFollowUps]),
            ([.reply("prose"), MetadataHarness.goodTitle], [MetadataHarness.goodFollowUps]),
            ([.reply("prose")], [MetadataHarness.goodFollowUps]),
            ([.fail("offline")], [.fail("offline")]),
            ([.cancel], [.cancel])
        ]
        for script in scripts {
            let completer = ScriptedCompleter(title: script.title, followUps: script.followUps)
            let pipeline = try await MetadataHarness.pipeline(completer: completer)
            let (_, trace) = await MetadataHarness.generate(pipeline)
            #expect(trace.refusal == nil, "metadata raised a refusal for \(script)")
        }
    }
}

// MARK: - Per-ask failure classification

@Suite("Metadata ask failures")
struct MetadataAskFailureTests {
    /// Cancellation arrives in two incompatible shapes, and a Stop button that showed an error
    /// banner to a user who deliberately walked away is the bug this handles.
    @Test("both shapes of cancellation are recognised as cancellation")
    func bothCancellationShapes() {
        let bare = MetadataAskFailure.make(ask: "a", from: CancellationError())
        #expect(bare.reason == .cancelled)

        let wrapped = MetadataAskFailure.make(
            ask: "a",
            from: RepairFailure.producerFailed(attempt: 2, message: "CancellationError()")
        )
        #expect(wrapped.reason == .cancelled)
        #expect(wrapped.attempts == 0)
    }

    @Test("exhaustion carries the attempt count and the unresolved issues")
    func exhaustion() {
        let issue = RepairIssue(path: "title", problem: "too long", expected: "48", observed: "90")
        let failure = MetadataAskFailure.make(
            ask: "chat.metadata.title",
            from: RepairFailure.exhausted(attempts: 3, issueHistory: [[], [issue]], lastRaw: "…")
        )
        #expect(failure.attempts == 3)
        #expect(failure.issues == [issue.description])
        #expect(failure.description.contains("still invalid after 3 attempt(s)"))
    }

    /// `RepairFailure.exhausted` carries the rejected reply, and in a chat app that text routinely
    /// quotes the user straight back. It must not survive into a trace.
    @Test("the rejected reply never reaches the failure's description")
    func doesNotLeakTheReply() {
        let failure = MetadataAskFailure.make(
            ask: "chat.metadata.title",
            from: RepairFailure.exhausted(
                attempts: 3,
                issueHistory: [[RepairIssue(path: "title", problem: "blank")]],
                lastRaw: "my bank account is 12345678"
            )
        )
        #expect(!failure.description.contains("12345678"))
    }

    @Test("a transport failure keeps the attempt it died on and stays readable")
    func providerFailure() {
        let failure = MetadataAskFailure.make(
            ask: "chat.metadata.title",
            from: RepairFailure.producerFailed(attempt: 1, message: "rate limited by OpenRouter")
        )
        #expect(failure.attempts == 1)
        #expect(failure.issues.isEmpty)
        #expect(failure.description.contains("rate limited by OpenRouter"))
    }

    @Test("anything else is reported as it stands rather than swallowed")
    func unknownError() {
        let failure = MetadataAskFailure.make(ask: "a", from: MetadataProviderFailure(summary: "boom"))
        #expect(failure.description.contains("boom"))
    }

    @Test("an id nothing is registered under is named as an app bug")
    func unknownAsk() {
        let failure = MetadataAskFailure(ask: "ghost", reason: .unknownAsk)
        #expect(failure.attempts == 0)
        #expect(failure.description.contains("no ask is registered"))
    }

    @Test("exhaustion with no recorded issue still says something")
    func exhaustionWithoutIssues() {
        let failure = MetadataAskFailure(ask: "a", reason: .exhausted(attempts: 1, unresolved: []))
        #expect(failure.description.contains("no issue was recorded"))
    }

    @Test("an empty issue history is read as no unresolved issues rather than crashing")
    func emptyIssueHistory() {
        let failure = MetadataAskFailure.make(
            ask: "a",
            from: RepairFailure.exhausted(attempts: 1, issueHistory: [], lastRaw: "x")
        )
        #expect(failure.issues.isEmpty)
        #expect(failure.attempts == 1)
    }

    @Test("an ask reports whether it converged after a repair or gave up")
    func repairedFlag() {
        let converged = MetadataBatchExecutor.AskOutcome(attempts: 2, issues: ["i"], failure: nil)
        let firstTry = MetadataBatchExecutor.AskOutcome(attempts: 1, issues: [], failure: nil)
        let lost = MetadataBatchExecutor.AskOutcome(
            attempts: 3,
            issues: ["i"],
            failure: MetadataAskFailure(ask: "a", reason: .exhausted(attempts: 3, unresolved: ["i"]))
        )
        #expect(converged.repaired)
        #expect(!firstTry.repaired, "a first-try success was never repaired")
        #expect(!lost.repaired)
    }
}

@Suite("Metadata batch executor")
struct MetadataBatchExecutorTests {
    /// The report is per item, so an id with no loop behind it has to surface as that item's
    /// failure rather than as a batch that quietly returned nothing.
    @Test("a request id with no ask behind it fails only that item")
    func unknownAskFailsOneItem() async throws {
        let completer = ScriptedCompleter(
            title: [MetadataHarness.goodTitle],
            followUps: [MetadataHarness.goodFollowUps]
        )
        let executor = MetadataBatchExecutor(asks: [], loops: [:], completer: completer)
        let processor = BatchProcessor(
            executor: executor,
            limit: ConcurrencyLimit(2),
            policy: .continueOnFailure,
            recorder: nil
        )

        let report = try await processor.process([BatchRequest(id: "ghost", prompt: "p")])

        #expect(report.responses.isEmpty)
        #expect(report.failures.count == 1)
        #expect(report.failures[0].kind == .executorFailure)
        #expect(report.failures[0].message.contains("no ask is registered"))
        let outcomes = await executor.recorded()
        #expect(outcomes["ghost"]?.attempts == 0)
        #expect(outcomes["ghost"]?.repaired == false)
    }

    /// `report.failures` mixes a model that actually failed with a request that was never
    /// attempted. This app runs `.continueOnFailure`, so nothing is ever left unattempted today —
    /// but the trace has to keep telling the truth if that policy is ever changed.
    @Test("a request that was never attempted is reported as such, not as a refusal")
    func cancelledItemsAreNamedSeparately() async throws {
        let completer = ScriptedCompleter(title: [], followUps: [])
        let pipeline = try await MetadataHarness.pipeline(completer: completer)
        let report = BatchReport(
            outcomes: [
                .success(
                    BatchResponse(
                        id: MetadataAsk.titleID,
                        text: MetadataFixtures.titleJSON,
                        usage: BatchTokenUsage(promptTokens: 3, completionTokens: 4)
                    )
                ),
                .failure(
                    BatchItemError(
                        requestID: MetadataAsk.followUpsID,
                        message: "Not admitted; an earlier request failed.",
                        kind: .cancelled
                    )
                )
            ],
            stats: BatchStats(
                batchesProcessed: 1, requestsAdmitted: 1, succeeded: 1,
                failed: 0, cancelled: 1, peakActive: 1, usage: .zero
            )
        )

        var trace = PipelineTrace()
        await pipeline.recordBatch(report, asked: 2, since: DispatchTime.now(), trace: &trace)

        let detail = MetadataHarness.summary(trace, .batchInference)
        #expect(detail.contains("1 never attempted"))
        #expect(!detail.contains("failed:"), "a call nobody made did not refuse anybody")
        #expect(detail.contains("7 token(s)"))
    }

    @Test("the audit trail records admission and completion for every ask")
    func recordsEvents() async throws {
        let recorder = InMemoryBatchEventRecorder()
        let completer = ScriptedCompleter(
            title: [MetadataHarness.goodTitle],
            followUps: [MetadataHarness.goodFollowUps]
        )
        let pipeline = try await MetadataHarness.pipeline(completer: completer, recorder: recorder)
        _ = await MetadataHarness.generate(pipeline)

        let events = await recorder.events
        #expect(events.contains { $0.kind == .batchStarted(count: 2) })
        #expect(events.contains { $0.kind == .succeeded(id: MetadataAsk.titleID) })
        #expect(events.contains { "\($0.kind)".contains("batchFinished") })
    }
}
