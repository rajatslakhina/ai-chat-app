import DelayCurveKit
import EvalHarness
import ExplorationChannelKit
import Foundation
import Testing
@testable import AIChatApp

/// The `delayCurve` stage, and the one stage in this trio that can compute and still must not.
///
/// `delaySignal` needs two separable rates and `delayShape` needs a family to fit; both decline
/// here. A product-limit estimate needs neither, so on this app's ledger it produces a perfectly
/// well-formed curve — and that curve is wrong in a way nothing in the data reveals. A label and a
/// cutoff land in the same tick, the estimator finds an event at its support limit, and it reports
/// the distribution complete while a share of the admissions never reached a verdict at all.
///
/// So this suite pins two things: the refusal this app actually reaches, with the reason spelled
/// out rather than shortened, and the findings the stage would produce the day verification moves
/// off the turn.
@Suite("Delay curve stage")
struct DelayCurveStageTests {
    func sample(returned: [Int], outstanding: [Int] = []) throws -> CurveSample {
        try CurveSample(
            returned.map { .returned(afterTicks: $0) } + outstanding.map { .outstanding(forTicks: $0) }
        )
    }

    /// Volume before variety. Three labels sharing a tick is a small sample, not a process with no
    /// delay in it, and an operator told otherwise would stop waiting for traffic that would help.
    @Test("too few labels reads as waiting on volume, not as a verdict about the delay")
    func belowTheVolumeGate() throws {
        let outcome = MetadataPipeline.curveOutcome(for: try sample(returned: [1, 1, 1], outstanding: [1]))
        guard case .skipped(let reason) = outcome else {
            Issue.record("expected a skip, got \(outcome)")
            return
        }
        #expect(reason.contains("3 labels have come back"))
        #expect(reason.contains("waiting on volume"))
    }

    /// The arm this app actually reaches, and the wording is the point.
    @Test("a single-tick delay with admissions outstanding names the assumption it breaks")
    func informativeCensoring() throws {
        let outcome = MetadataPipeline.curveOutcome(
            for: try sample(returned: Array(repeating: 1, count: 20), outstanding: Array(repeating: 1, count: 6))
        )
        guard case .skipped(let reason) = outcome else {
            Issue.record("expected a skip, got \(outcome)")
            return
        }
        #expect(reason.contains("calls the distribution complete"))
        #expect(reason.contains("6 never resolved at all"))
        #expect(reason.contains("never reached a verdict"))
        #expect(reason.contains("No amount of traffic fixes it"))
    }

    /// Everything labelled and everything in one tick: still no distribution, but the sentence
    /// above would be a lie because nothing is outstanding to be wrong about.
    @Test("a single-tick delay with nothing outstanding says so without the censoring claim")
    func inlineWithNothingOutstanding() throws {
        let outcome = MetadataPipeline.curveOutcome(for: try sample(returned: Array(repeating: 1, count: 15)))
        guard case .skipped(let reason) = outcome else {
            Issue.record("expected a skip, got \(outcome)")
            return
        }
        #expect(reason.contains("Verification here is inline"))
        #expect(!reason.contains("never resolved at all"))
    }

    /// The day a verifier moves off the turn. An improper curve must say where it stops rather than
    /// implying the remaining mass sits just past the edge.
    @Test("a real spread of delays produces a curve, and an improper one says where it stops")
    func aRealCurve() throws {
        let outcome = MetadataPipeline.curveOutcome(
            for: try sample(returned: [1, 2, 2, 3, 4, 4, 5, 6, 7, 8, 9, 11], outstanding: [14, 14])
        )
        guard case .ran(let detail) = outcome else {
            Issue.record("expected a run, got \(outcome)")
            return
        }
        #expect(detail.contains("support to t14"))
        #expect(detail.contains("it stops at"))
        #expect(detail.contains("not in the data"))
        // Six, not five, and the one tick of difference is a real property rather than a typo.
        // Survival at t5 is mathematically exactly 0.5 — 13/14 x 11/13 x 10/11 x 8/10 x 7/8 — but
        // the estimator accumulates that as a running product and lands on 0.5000000000000001, so
        // "first tick at or below a half" steps past it. See `firstTick(atOrBelow:)`.
        #expect(detail.contains("median 6 ticks"))
    }

    @Test("a complete curve says every request reported")
    func aProperCurve() throws {
        let outcome = MetadataPipeline.curveOutcome(for: try sample(returned: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]))
        guard case .ran(let detail) = outcome else {
            Issue.record("expected a run, got \(outcome)")
            return
        }
        #expect(detail.contains("every request reported"))
        #expect(detail.contains("12 steps over 12 requests"))
    }

    /// A curve too shallow to have a median must not invent one from the largest observed tick.
    @Test("a curve that never falls to half says it has no median rather than guessing")
    func noMedianInsideSupport() throws {
        let outcome = MetadataPipeline.curveOutcome(
            for: try sample(returned: Array(1...12), outstanding: Array(repeating: 40, count: 60))
        )
        guard case .ran(let detail) = outcome else {
            Issue.record("expected a run, got \(outcome)")
            return
        }
        #expect(detail.contains("no median inside the support"))
    }

    // MARK: - Through the ledger

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

    @Test("an empty ledger is a no-op with a reason, not a silent pass")
    func emptyLedger() async {
        var trace = PipelineTrace()
        await pipeline().auditDelayCurve(trace: &trace, ledger: ExplorationLedger())
        let record = trace.records.first { $0.stage == .delayCurve }
        #expect(
            record?.outcome
                == .noOp(reason: "nothing has been explored yet — there are no arrival times to curve")
        )
    }

    @Test("admissions with no labels yet are a no-op rather than a curve of nothing")
    func admittedButUnlabelled() async {
        let ledger = ExplorationLedger()
        await admitted(["explore-0", "explore-1"], into: ledger)
        var trace = PipelineTrace()
        await pipeline().auditDelayCurve(trace: &trace, ledger: ledger)
        let record = trace.records.first { $0.stage == .delayCurve }
        #expect(
            record?.outcome
                == .noOp(reason: "no exploration has been labelled yet — nothing has arrived to curve")
        )
    }

    @Test("a real ledger from this app reaches the volume gate first")
    func realLedgerFromThisApp() async {
        let ledger = ExplorationLedger()
        await admitted(["explore-0", "explore-1", "explore-2"], into: ledger)
        await ledger.label("explore-0", loss: 1)
        await ledger.label("explore-1", loss: 0)
        var trace = PipelineTrace()
        await pipeline().auditDelayCurve(trace: &trace, ledger: ledger)
        let record = trace.records.first { $0.stage == .delayCurve }
        guard case .skipped(let reason)? = record?.outcome else {
            Issue.record("expected a skip, got \(String(describing: record?.outcome))")
            return
        }
        #expect(reason.contains("waiting on volume"))
    }

    /// The ledger form at the volume this app would need: the censoring arm, reached for real
    /// rather than only through the static entry point.
    @Test("a ledger with enough labels reaches the informative-censoring skip")
    func ledgerAtVolume() async {
        let ledger = ExplorationLedger()
        let ids = (0..<16).map { "explore-\($0)" }
        await admitted(ids, into: ledger)
        for id in ids.prefix(12) {
            await ledger.label(id, loss: 0)
        }
        var trace = PipelineTrace()
        await pipeline().auditDelayCurve(trace: &trace, ledger: ledger)
        let record = trace.records.first { $0.stage == .delayCurve }
        guard case .skipped(let reason)? = record?.outcome else {
            Issue.record("expected a skip, got \(String(describing: record?.outcome))")
            return
        }
        #expect(reason.contains("calls the distribution complete"))
        #expect(reason.contains("4 never resolved at all"))
    }

    @Test("the stage is owned by the package that implements it")
    func stageNamesItsPackage() {
        #expect(PipelineStage.delayCurve.package == "DelayCurveKit")
        #expect(PipelineStage.delayCurve.title == "Delay curve")
    }
}
