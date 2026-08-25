import DelaySignalKit
import EvalHarness
import ExplorationChannelKit
import Foundation
import Testing
@testable import AIChatApp

/// The `delaySignal` stage, driven with panels this app cannot currently produce.
///
/// That gap is the point rather than a testing convenience. This app verifies inline: an
/// exploration is admitted and labelled inside one turn, so every delay it can generate is the
/// same number and the correcting path is unreachable from the send pipeline. Asserting the
/// unreachable path here is what makes the *reachable* one an honest measurement instead of a
/// claim, and it is what will already be right the day a verifier moves off the turn.
@Suite("Delay signal stage")
struct DelaySignalStageTests {
    func panel(
        asOf: Int,
        returned: [(String, LabelClass, Double, Double)],
        outstanding: [(String, Double)] = []
    ) -> DelayPanel {
        DelayPanel(
            asOf: LogicalTime(asOf),
            returned: returned.map { ReturnedDelay(id: $0.0, label: $0.1, delay: $0.2, elapsed: $0.3) },
            outstanding: outstanding.map { OutstandingWait(id: $0.0, elapsed: $0.1) }
        )
    }

    @Test("nothing labelled yet is a no-op, not a risk of zero")
    func nothingLabelled() {
        let outcome = MetadataPipeline.outcome(for: panel(asOf: 5, returned: [], outstanding: [("a", 5)]))
        #expect(outcome == .noOp(reason: "no exploration has been labelled yet — nothing has arrived to time"))
    }

    /// The arm this app actually reaches, and the reason it exists.
    @Test("one distinct delay is inline verification, and says so")
    func inlineVerification() {
        let outcome = MetadataPipeline.outcome(
            for: panel(
                asOf: 1,
                returned: [("a", .loss, 1, 1), ("b", .noLoss, 1, 1), ("c", .noLoss, 1, 1)],
                outstanding: [("d", 1), ("e", 1)]
            )
        )
        guard case .skipped(let reason) = outcome else {
            Issue.record("expected a skip, got \(outcome)")
            return
        }
        #expect(reason.contains("verifies inline"))
        #expect(reason.contains("all 3 labels"))
        #expect(reason.contains("2 admissions still unlabelled are not slow"))
    }

    @Test("a real gap in arrival times produces a correction")
    func realDelayCorrects() {
        var returned: [(String, LabelClass, Double, Double)] = []
        for index in 0..<40 {
            returned.append(("loss\(index)", .loss, 12, 40))
            returned.append(("clean\(index)", .noLoss, 3, 40))
        }
        let outcome = MetadataPipeline.outcome(
            for: panel(asOf: 40, returned: returned, outstanding: [("pending", 40)])
        )
        guard case .ran(let detail) = outcome else {
            Issue.record("expected a correction, got \(outcome)")
            return
        }
        #expect(detail.contains("closing the books reports"))
        #expect(detail.contains("separated at"))
    }

    @Test("varied arrivals that carry no signal are skipped with the measured reason")
    func variedButUninformative() {
        var returned: [(String, LabelClass, Double, Double)] = []
        for index in 0..<20 {
            returned.append(("loss\(index)", .loss, Double(2 + index % 5), 40))
            returned.append(("clean\(index)", .noLoss, Double(2 + index % 5), 40))
        }
        let outcome = MetadataPipeline.outcome(
            for: panel(asOf: 40, returned: returned, outstanding: [("pending", 40)])
        )
        guard case .skipped(let reason) = outcome else {
            Issue.record("expected a skip, got \(outcome)")
            return
        }
        #expect(reason.hasPrefix("no delay correction — "))
    }

    /// A delay of zero cannot be fitted — an exponential rate over no exposure is not a rate. The
    /// stage reports the failure rather than letting the throw escape into a background task.
    @Test("an unfittable panel is a failure, not a silent pass")
    func unfittablePanel() {
        let outcome = MetadataPipeline.outcome(
            for: panel(
                asOf: 4,
                returned: [
                    ("a", .loss, 0, 4), ("b", .loss, 0, 4), ("c", .loss, 0, 4),
                    ("d", .noLoss, 2, 4), ("e", .noLoss, 3, 4), ("f", .noLoss, 4, 4)
                ],
                outstanding: [("g", 4)]
            )
        )
        #expect(outcome == .failed(message: "the delay panel could not be fitted"))
    }

    // MARK: - the actor path, as the send pipeline reaches it

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
        await pipeline().auditDelaySignal(trace: &trace, ledger: ExplorationLedger())
        let record = trace.records.first { $0.stage == .delaySignal }
        #expect(
            record?.outcome
                == .noOp(reason: "nothing has been explored yet — there are no arrival times to read")
        )
    }

    /// What this app actually produces today: admissions on file, labels attached inside the same
    /// turn, and therefore one delay value across the whole panel.
    @Test("a real ledger from this app reaches the inline-verification skip")
    func realLedgerIsInline() async {
        let ledger = ExplorationLedger()
        await admitted(["explore-0", "explore-1", "explore-2"], into: ledger)
        await ledger.label("explore-0", loss: 1)
        await ledger.label("explore-1", loss: 0)
        await ledger.label("explore-2", loss: 0)
        var trace = PipelineTrace()
        await pipeline().auditDelaySignal(trace: &trace, ledger: ledger)
        let record = trace.records.first { $0.stage == .delaySignal }
        guard case .skipped(let reason)? = record?.outcome else {
            Issue.record("expected a skip, got \(String(describing: record?.outcome))")
            return
        }
        #expect(reason.contains("verifies inline"))
    }

    @Test("admissions with no labels yet are a no-op rather than a risk of zero")
    func admittedButUnlabelled() async {
        let ledger = ExplorationLedger()
        await admitted(["explore-0", "explore-1"], into: ledger)
        var trace = PipelineTrace()
        await pipeline().auditDelaySignal(trace: &trace, ledger: ledger)
        let record = trace.records.first { $0.stage == .delaySignal }
        guard case .noOp(let reason)? = record?.outcome else {
            Issue.record("expected a no-op, got \(String(describing: record?.outcome))")
            return
        }
        #expect(reason.contains("nothing has arrived to time"))
    }

    /// The two stages must not disagree about which admissions exist, so both read the ledger
    /// through the same audit plan.
    @Test("the snapshot holds every admission the ledger does")
    func snapshotMatchesLedger() async {
        let ledger = ExplorationLedger()
        await admitted(["explore-0", "explore-1", "explore-2"], into: ledger)
        await ledger.label("explore-0", loss: 1)
        let entries = await ledger.allEntries
        guard let snapshot = await MetadataPipeline.delayPanelSnapshot(entries: entries) else {
            Issue.record("expected a snapshot from a ledger with three admissions")
            return
        }
        #expect(snapshot.admissionCount == 3)
        #expect(snapshot.returned.count == 1)
        #expect(snapshot.pending.count == 2)
    }

    private func entry(_ id: String, loss: Double?) -> ExplorationEntry {
        ExplorationEntry(
            id: id,
            depth: 0.05,
            cost: 0.05,
            admissionProbability: ExplorationBudget.frequency,
            stratum: nil,
            observedLoss: loss
        )
    }

    /// An `ExplorationLedger` cannot produce this, which is why the entry-list form exists: the arm
    /// is real, it is just not reachable through the actor that normally feeds it.
    @Test("an entry list this app cannot produce is skipped, not crashed on")
    func unreadableLedger() async {
        var trace = PipelineTrace()
        await pipeline().auditDelaySignal(
            trace: &trace,
            entries: [entry("explore-0", loss: 1), entry("explore-0", loss: 0)]
        )
        let record = trace.records.first { $0.stage == .delaySignal }
        #expect(
            record?.outcome
                == .skipped(reason: "the exploration ledger could not be read as a return ledger")
        )
    }

    @Test("a duplicate id gives no snapshot rather than a merged one")
    func duplicateIDGivesNoSnapshot() async {
        let snapshot = await MetadataPipeline.delayPanelSnapshot(
            entries: [entry("explore-0", loss: 1), entry("explore-0", loss: 0)]
        )
        #expect(snapshot == nil)
    }

    @Test("the stage names its package and its title")
    func stageIdentity() {
        #expect(PipelineStage.delaySignal.package == "DelaySignalKit")
        #expect(PipelineStage.delaySignal.title == "Delay signal")
        #expect(PipelineStage.delaySignal.id == "delaySignal")
    }
}
