import EvalHarness
import ExplorationChannelKit
import Foundation
import LabelClockKit
import Testing
@testable import AIChatApp

/// The `labelClock` stage, which measures what the four delay stages beside it assert.
///
/// Those four each decline for a reason of their own and each reason ends in the same place: this
/// app records *whether a verdict arrived* and *what it said* in one field. This stage builds the
/// same ledger under both readings of "cohort" and reports the one number that differs — how many
/// admissions can carry a censored observation — then says what is still wrong after that number
/// improves.
///
/// The suite pins both audits, the arithmetic behind the recovered count, and the two sentences
/// that stop a recovered count being read as a green light.
@Suite("Label clock stage")
struct LabelClockStageTests {
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
        await pipeline().auditLabelClock(trace: &trace, ledger: ExplorationLedger())
        let record = trace.records.first { $0.stage == .labelClock }
        #expect(
            record?.outcome
                == .noOp(reason: "nothing has been admitted yet — there is no ledger to audit")
        )
    }

    /// The measurement, driven through the real ledger rather than the static entry point.
    @Test("a real ledger is audited under both cohorts and both verdicts are reported")
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
        await pipeline().auditLabelClock(trace: &trace, ledger: ledger)
        let record = trace.records.first { $0.stage == .labelClock }
        guard case .ran(let detail)? = record?.outcome else {
            Issue.record("expected the stage to run, got \(String(describing: record?.outcome))")
            return
        }
        #expect(detail.contains("cohort from observedLoss: conflated"))
        #expect(detail.contains("phi 1.0000"))
        #expect(detail.contains("0 of 10 admissions censorable"))
        #expect(detail.contains("7 of 7 classified in the same tick the label landed"))
        #expect(detail.contains("3 of 10 censorable"))
    }

    /// A ledger that cannot be read as an observation ledger fails loudly rather than reporting a
    /// clean audit over whatever survived. Reached through the entry list, because the actor's own
    /// store is keyed by identifier and cannot produce this — the same reason the sibling stages
    /// take an entry list as well as a ledger.
    @Test("an unreadable entry list fails rather than auditing what is left of it")
    func duplicateIdentifiersFailRatherThanBeingDropped() async {
        let duplicated = (0..<2).map { _ in
            ExplorationEntry(
                id: "same", depth: 1, cost: 0.05,
                admissionProbability: 0.5, stratum: nil, observedLoss: nil
            )
        }
        var trace = PipelineTrace()
        await pipeline().auditLabelClock(trace: &trace, entries: duplicated)
        let record = trace.records.first { $0.stage == .labelClock }
        #expect(
            record?.outcome
                == .failed(message: "the exploration ledger could not be read as an observation ledger")
        )
    }

    /// The proof, not the prose: the cohort this app splits on is the arrival indicator, so the
    /// audit reaches the strongest of the three conflation reasons rather than a weaker one.
    @Test("the outcome cohort is the arrival indicator, and the audit names it as that")
    func outcomeCohortIsTheArrivalIndicator() async throws {
        let ledger = ExplorationLedger()
        let ids = (0..<8).map { "explore-\($0)" }
        await admitted(ids, into: ledger)
        for id in ids.prefix(5) {
            await ledger.label(id, loss: 1)
        }
        let entries = await ledger.allEntries
        let built = try #require(MetadataPipeline.clockLedger(entries: entries, cohort: .outcome))
        let audit = await LedgerAuditor().audit(built)
        #expect(audit.verdict == .conflated(.classIndicatorIsArrivalIndicator))
        #expect(audit.table.censorableUnits == 0)
        #expect(audit.clocks.leadingCount == 0)
        #expect(audit.greatestUsefulLandmark == nil)
        #expect(!audit.isUsable)
    }

    /// The same entries under a cohort fixed at admission, which is the half with a remedy.
    @Test("the admission cohort recovers exactly the unlabelled admissions as censorable")
    func admissionCohortRecoversTheCensoring() async throws {
        let ledger = ExplorationLedger()
        let ids = (0..<8).map { "explore-\($0)" }
        await admitted(ids, into: ledger)
        for id in ids.prefix(5) {
            await ledger.label(id, loss: 0)
        }
        let entries = await ledger.allEntries
        let built = try #require(MetadataPipeline.clockLedger(entries: entries, cohort: .admission))
        let audit = await LedgerAuditor().audit(built)
        #expect(audit.table.censorableUnits == 3)
        #expect(audit.table.classified == 8)
        #expect(audit.verdict == .separated(censorableUnits: 3))
        #expect(audit.clocks.leadingCount == 5)
    }

    /// A recovered count is not a green light, and the stage has to say so in the same breath.
    @Test("the remainder names the clock and the confounded cohort, not just the recovered count")
    func theRemainderRefusesToReadAsAGreenLight() {
        let remainder = MetadataPipeline.clockRemainder(recovered: 3)
        #expect(remainder.contains("The clock is one tick wide"))
        #expect(remainder.contains("bought precisely to obtain a label"))
        #expect(remainder.contains("Recovering 3 censorable admissions"))
        #expect(remainder.contains("without making the comparison valid"))
    }

    /// When nothing is recovered the cohort was not the only thing wrong, and that is a different
    /// sentence rather than the same one with a zero in it.
    @Test("recovering nothing is reported as a different finding")
    func recoveringNothingIsItsOwnSentence() {
        let remainder = MetadataPipeline.clockRemainder(recovered: 0)
        #expect(remainder.contains("Nothing became censorable"))
        #expect(!remainder.contains("has a remedy available today"))
    }

    /// The cohort taken from the outcome is stamped with the arrival tick, not with admission.
    /// Backdating it would assert knowledge this app never had.
    @Test("an outcome cohort is timestamped when the label landed, not when the turn was admitted")
    func outcomeCohortCarriesTheArrivalTick() {
        let entry = ExplorationEntry(
            id: "u1",
            depth: 1,
            cost: 0.05,
            admissionProbability: 0.5,
            stratum: nil,
            observedLoss: 1
        )
        let arrival = LabelArrival(at: MetadataPipeline.clockObservedThrough, content: "loss")
        let assignment = MetadataPipeline.clockAssignment(entry: entry, arrival: arrival, cohort: .outcome)
        #expect(assignment?.assignedAt == MetadataPipeline.clockObservedThrough)
        #expect(assignment?.cohort == "loss")
        let unlabelled = MetadataPipeline.clockAssignment(entry: entry, arrival: nil, cohort: .outcome)
        #expect(unlabelled == nil)
    }

    /// The admission cohort exists for every entry, labelled or not — which is the whole point.
    @Test("an admission cohort exists before any label does, for every entry")
    func admissionCohortAlwaysExists() {
        let explored = ExplorationEntry(
            id: "u1", depth: 1, cost: 0.05, admissionProbability: 0.5, stratum: nil, observedLoss: nil
        )
        let answered = ExplorationEntry(
            id: "u2", depth: 1, cost: 0, admissionProbability: 1, stratum: nil, observedLoss: nil
        )
        let first = MetadataPipeline.clockAssignment(entry: explored, arrival: nil, cohort: .admission)
        let second = MetadataPipeline.clockAssignment(entry: answered, arrival: nil, cohort: .admission)
        #expect(first?.cohort == "explored")
        #expect(second?.cohort == "answered")
        #expect(first?.assignedAt == MetadataPipeline.clockAdmittedAt)
        #expect(second?.assignedAt == MetadataPipeline.clockAdmittedAt)
    }

    /// The outcome the stage records is derived from the two audits, so it can be driven with
    /// audits this app cannot currently produce.
    @Test("the recorded outcome is a run, carrying both verdicts")
    func outcomeCarriesBothVerdicts() {
        let fused = ClockAudit(
            table: SeparationTable(
                classifiedAndArrived: 6, classifiedAndOutstanding: 0,
                unclassifiedAndArrived: 0, unclassifiedAndOutstanding: 4
            ),
            clocks: ClockSeparation(leads: Array(repeating: 0, count: 6)),
            verdict: .conflated(.classIndicatorIsArrivalIndicator)
        )
        let admission = ClockAudit(
            table: SeparationTable(
                classifiedAndArrived: 6, classifiedAndOutstanding: 4,
                unclassifiedAndArrived: 0, unclassifiedAndOutstanding: 0
            ),
            clocks: ClockSeparation(leads: Array(repeating: 1, count: 6)),
            verdict: .separated(censorableUnits: 4)
        )
        guard case .ran(let detail) = MetadataPipeline.clockOutcome(outcome: fused, admission: admission) else {
            Issue.record("expected a run")
            return
        }
        #expect(detail.contains("0 of 10 admissions censorable"))
        #expect(detail.contains("separated (4 censorable units), 4 of 10 censorable"))
    }
}
