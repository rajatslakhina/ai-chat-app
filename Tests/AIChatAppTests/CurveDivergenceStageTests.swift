import CurveDivergenceKit
import DelayCurveKit
import EvalHarness
import ExplorationChannelKit
import Foundation
import Testing
@testable import AIChatApp

/// The `curveDivergence` stage, and the reason it declines that none of its three siblings has.
///
/// `delaySignal` needs two separable rates. `delayShape` needs one of four families to fit.
/// `delayCurve` can compute and must not, because the censoring here is informative. This one
/// cannot get as far as computing, for two reasons that are independent of each other: the shared
/// window is one tick wide, so a supremum degenerates into a difference of two proportions; and the
/// class label and the event indicator are the same field, so forming the arms deletes every
/// censored observation and leaves a comparison with nothing for survival analysis to do.
///
/// The suite pins the refusal this app reaches with its wording intact, and the findings the stage
/// would produce the day verification moves off the turn.
@Suite("Curve divergence stage")
struct CurveDivergenceStageTests {
    private func pipeline() async -> MetadataPipeline {
        MetadataPipeline(
            completer: ScriptedCompleter(
                title: [MetadataHarness.goodTitle],
                followUps: [MetadataHarness.goodFollowUps]
            ),
            contracts: await Composition.makeContracts(),
            transcripts: InMemoryTranscriptStore()
        )
    }

    private func admitted(_ ids: [String], into ledger: ExplorationLedger) async {
        for id in ids {
            let candidate = ExplorationBudget.candidate(id: id, score: 0.35, threshold: 0.30)
            await ledger.record(
                candidate,
                ruling: .admitted(cost: 0.05, admissionProbability: ExplorationBudget.frequency)
            )
        }
    }

    private func arm(returned: [Int], outstanding: [Int] = []) throws -> CurveSample {
        try CurveSample(
            returned.map { .returned(afterTicks: $0) } + outstanding.map { .outstanding(forTicks: $0) }
        )
    }

    @Test("an empty ledger is a no-op with a reason, not a silent pass")
    func emptyLedger() async {
        var trace = PipelineTrace()
        await pipeline().auditCurveDivergence(trace: &trace, ledger: ExplorationLedger())
        let record = trace.records.first { $0.stage == .curveDivergence }
        #expect(
            record?.outcome
                == .noOp(reason: "nothing has been explored yet — there are no curves to compare")
        )
    }

    /// One class with nothing in it is one curve and an absence, which is not a comparison.
    @Test("a ledger whose labels are all one class is a no-op rather than a one-armed test")
    func oneClassOnly() async {
        let ledger = ExplorationLedger()
        let ids = (0..<6).map { "explore-\($0)" }
        await admitted(ids, into: ledger)
        for id in ids.prefix(4) {
            await ledger.label(id, loss: 0)
        }
        var trace = PipelineTrace()
        await pipeline().auditCurveDivergence(trace: &trace, ledger: ledger)
        let record = trace.records.first { $0.stage == .curveDivergence }
        guard case .noOp(let reason)? = record?.outcome else {
            Issue.record("expected a no-op, got \(String(describing: record?.outcome))")
            return
        }
        #expect(reason.contains("nothing to compare it against"))
    }

    /// The arm this app actually reaches, driven through the real ledger rather than the static
    /// entry point, and the wording is the point.
    @Test("a real ledger reaches the degenerate-window skip with both reasons named")
    func realLedgerFromThisApp() async {
        let ledger = ExplorationLedger()
        let ids = (0..<10).map { "explore-\($0)" }
        await admitted(ids, into: ledger)
        for id in ids.prefix(3) {
            await ledger.label(id, loss: 1)
        }
        for id in ids.dropFirst(3).prefix(4) {
            await ledger.label(id, loss: 0)
        }
        var trace = PipelineTrace()
        await pipeline().auditCurveDivergence(trace: &trace, ledger: ledger)
        let record = trace.records.first { $0.stage == .curveDivergence }
        guard case .skipped(let reason)? = record?.outcome else {
            Issue.record("expected a skip, got \(String(describing: record?.outcome))")
            return
        }
        #expect(reason.contains("the shared window is one tick wide"))
        #expect(reason.contains("the class label and the event indicator are the same field"))
        // Three admissions were never labelled, so they had no class to join.
        #expect(reason.contains("3 unlabelled admissions had no class to join"))
        #expect(reason.contains("3-against-4 comparison"))
    }

    /// The arms come back with no censoring in them, which is the half of the refusal a longer
    /// clock would not fix. Pinned directly so the claim in the skip text is not only prose.
    @Test("forming the arms deletes every censored observation")
    func armsAreUncensoredByConstruction() async {
        let ledger = ExplorationLedger()
        let ids = (0..<9).map { "explore-\($0)" }
        await admitted(ids, into: ledger)
        for id in ids.prefix(2) {
            await ledger.label(id, loss: 1)
        }
        for id in ids.dropFirst(2).prefix(3) {
            await ledger.label(id, loss: 0)
        }
        let split = MetadataPipeline.divergenceSample(entries: await ledger.allEntries)
        let unwrapped = try? #require(split)
        guard let unwrapped else { return }
        #expect(unwrapped.dropped == 4)
        #expect(unwrapped.sample.first.outstandingCount == 0)
        #expect(unwrapped.sample.second.outstandingCount == 0)
        #expect(unwrapped.sample.first.count == 2)
        #expect(unwrapped.sample.second.count == 3)
        #expect(unwrapped.sample.sharedSupport == 1)
    }

    /// What the stage does the day admissions carry a real clock: it runs, and it reports the tick.
    @Test("on a panel with a real clock the stage runs and names where the curves part")
    func runsOnAPanelWithARealClock() throws {
        let loss = try arm(returned: [7, 7, 8, 8, 9, 9, 10, 11, 12, 13], outstanding: [15, 15, 15])
        let clean = try arm(returned: [1, 1, 2, 2, 2, 3, 3, 4, 5, 6], outstanding: [15, 15, 15])
        let outcome = MetadataPipeline.divergenceOutcome(for: DivergenceSample(first: loss, second: clean))
        guard case .ran(let detail) = outcome else {
            Issue.record("expected a run, got \(outcome)")
            return
        }
        #expect(detail.contains("stays above throughout"))
        #expect(detail.contains("over t0-t15"))
        #expect(detail.contains("KS "))
        #expect(detail.contains("Kuiper "))
    }

    /// A panel the package itself refuses, so the stage's decline arm is reached rather than only
    /// its degenerate-window arm.
    @Test("a package-level refusal reaches the stage as a skip carrying the package's own reason")
    func packageRefusalBecomesASkip() throws {
        let loss = try arm(returned: [2, 4, 6], outstanding: [8])
        let clean = try arm(returned: [3, 5], outstanding: [8])
        let outcome = MetadataPipeline.divergenceOutcome(for: DivergenceSample(first: loss, second: clean))
        guard case .skipped(let reason) = outcome else {
            Issue.record("expected a skip, got \(outcome)")
            return
        }
        #expect(reason.contains("labels back"))
    }

    /// The strain flag reaches the detail line. Two arms read at different times — one with 40%
    /// of its admissions still outstanding, one with none — is exactly the shape a permutation
    /// null cannot tell apart from a genuine difference in speed, so the number is printed.
    @Test("a lopsided censoring gap is reported in the detail rather than swallowed")
    func lopsidedCensoringReachesTheDetail() throws {
        let loss = try arm(
            returned: [2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13],
            outstanding: Array(repeating: 15, count: 8)
        )
        let clean = try arm(returned: [1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6])
        let outcome = MetadataPipeline.divergenceOutcome(for: DivergenceSample(first: loss, second: clean))
        guard case .ran(let detail) = outcome else {
            Issue.record("expected a run, got \(outcome)")
            return
        }
        #expect(detail.contains("exchangeability is under strain"))
        #expect(detail.contains("40% between the arms"))
    }

    /// Not separating is a run, not a skip. The stage reports what it measured; a stage that only
    /// recorded a result when the result was interesting would make the trace unreadable as
    /// evidence, because absence would mean two different things.
    @Test("two arms drawn alike run and report no separation rather than skipping")
    func noSeparationIsStillARun() throws {
        let ticks = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]
        let loss = try arm(returned: ticks, outstanding: [14, 14])
        let clean = try arm(returned: ticks, outstanding: [14, 14])
        let outcome = MetadataPipeline.divergenceOutcome(for: DivergenceSample(first: loss, second: clean))
        guard case .ran(let detail) = outcome else {
            Issue.record("expected a run, got \(outcome)")
            return
        }
        #expect(detail.contains("no gap clears the floor in either direction"))
        #expect(detail.contains("KS 0.0000"))
    }

    @Test("the stage is owned by the package that implements it")
    func stageNamesItsPackage() {
        #expect(PipelineStage.curveDivergence.package == "CurveDivergenceKit")
        #expect(PipelineStage.curveDivergence.title == "Curve divergence")
    }
}
