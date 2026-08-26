import DelayShapeKit
import DelayShapeSignal
import DelaySignalKit
import EvalHarness
import ExplorationChannelKit
import Foundation
import Testing
@testable import AIChatApp

/// The `delayShape` stage, driven with panels this app cannot currently produce.
///
/// Same gap as its sibling and the same reason for asserting past it. This app verifies inline, so
/// every delay it can generate is the same number — and that is not merely "no separation between
/// the classes", which is what `delaySignal` reports. It is *no delay distribution at all*: under
/// the truncated likelihood every candidate shape explains a single-valued delay perfectly, so the
/// ranking is decided on parameter count and the winner's parameters are wherever the search
/// started. `DelayShapeKit` refuses that outright, and this suite pins both the refusal this app
/// reaches and the findings it would produce the day a verifier moves off the turn.
@Suite("Delay shape stage")
struct DelayShapeStageTests {
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

    /// Delays drawn from a fixed sequence, so a fitted shape here is reproducible rather than
    /// whatever the machine felt like on the day.
    func spread(_ label: LabelClass, base: Int, count: Int, prefix: String) -> [(String, LabelClass, Double, Double)] {
        (0..<count).map { index in
            (prefix + String(index), label, Double(base + index % 7), 60.0)
        }
    }

    @Test("nothing labelled yet is a no-op, not a shape of nothing")
    func nothingLabelled() {
        let outcome = MetadataPipeline.shapeOutcome(for: panel(asOf: 5, returned: [], outstanding: [("a", 5)]))
        #expect(
            outcome == .noOp(reason: "no exploration has been labelled yet — nothing has arrived to shape")
        )
    }

    /// The arm this app actually reaches. The wording matters as much as the arm: an operator told
    /// "insufficient evidence" would wait for traffic that cannot help.
    @Test("one distinct delay carries no shape, and the reason says more data will not help")
    func degenerateDelays() {
        var returned: [(String, LabelClass, Double, Double)] = []
        for index in 0..<40 {
            returned.append(("loss\(index)", .loss, 1, 1))
            returned.append(("clean\(index)", .noLoss, 1, 1))
        }
        let outcome = MetadataPipeline.shapeOutcome(for: panel(asOf: 1, returned: returned))
        guard case .skipped(let reason) = outcome else {
            Issue.record("expected a skip, got \(outcome)")
            return
        }
        #expect(reason.contains("verifies inline"))
        #expect(reason.contains("arrived in 1 distinct tick"))
        #expect(reason.contains("no amount of traffic will produce one"))
        #expect(reason.contains("never reached a verdict"))
    }

    @Test("a class with too few labels is undecided, and says which class")
    func tooFewLabels() {
        let outcome = MetadataPipeline.shapeOutcome(
            for: panel(
                asOf: 60,
                returned: spread(.noLoss, base: 2, count: 40, prefix: "clean")
                    + [("loss0", .loss, 9, 60), ("loss1", .loss, 14, 60)]
            )
        )
        guard case .skipped(let reason) = outcome else {
            Issue.record("expected a skip, got \(outcome)")
            return
        }
        #expect(reason.contains("no delay shape"))
        #expect(reason.contains("loss has 2 returned labels, needs 30"))
    }

    @Test("a class with no labels at all is undecided rather than assumed")
    func classMissing() {
        let outcome = MetadataPipeline.shapeOutcome(
            for: panel(asOf: 60, returned: spread(.noLoss, base: 2, count: 40, prefix: "clean"))
        )
        guard case .skipped(let reason) = outcome else {
            Issue.record("expected a skip, got \(outcome)")
            return
        }
        #expect(reason.contains("no returned labels for loss"))
    }

    /// The finding this stage exists to produce: a delay that is not memoryless, named, with what
    /// to use instead and how much the assumption was worth.
    @Test("a delay with a floor under it contradicts the constant hazard, and names the shape")
    func contradictsTheExponential() {
        var returned: [(String, LabelClass, Double, Double)] = []
        for index in 0..<60 {
            returned.append(("loss\(index)", .loss, Double(9 + index % 9), 90))
            returned.append(("clean\(index)", .noLoss, Double(2 + index % 5), 90))
        }
        let outcome = MetadataPipeline.shapeOutcome(for: panel(asOf: 90, returned: returned))
        guard case .ran(let detail) = outcome else {
            Issue.record("expected a finding, got \(outcome)")
            return
        }
        #expect(detail.contains("does not have a constant hazard"))
        #expect(detail.contains("AIC over"))
        #expect(detail.contains("leaning on the wrong tail"))
    }

    /// Delays that really are memoryless, by construction.
    ///
    /// Built from the exponential quantile function on an evenly spaced grid rather than from a
    /// pseudo-random stream, because a stratified sample is both deterministic and genuinely of the
    /// distribution. The first attempt at this fixture used an LCG modulo a prime, which is close to
    /// *uniform* — a rising hazard — and duly got reported as a contradiction. That was the stage
    /// working.
    func memoryless(_ label: LabelClass, rate: Double, count: Int, prefix: String)
        -> [(String, LabelClass, Double, Double)] {
        (0..<count).map { index in
            let quantile = (Double(index) + 0.5) / Double(count)
            let delay = max(1.0, (-log(1 - quantile) / rate).rounded(.up))
            return (prefix + String(index), label, delay, 400.0)
        }
    }

    /// The positive finding, which is not the same as no finding: the assumption every delay
    /// correction in this pipeline rests on was checked and survived.
    @Test("memoryless delays are reported as supported, not as silence")
    func supportsTheExponential() {
        let outcome = MetadataPipeline.shapeOutcome(
            for: panel(
                asOf: 400,
                returned: memoryless(.loss, rate: 0.1, count: 80, prefix: "loss")
                    + memoryless(.noLoss, rate: 0.25, count: 120, prefix: "clean")
            )
        )
        guard case .ran(let detail) = outcome else {
            Issue.record("expected a finding, got \(outcome)")
            return
        }
        #expect(detail.contains("memoryless within the evidence available"))
        #expect(detail.contains("the right one to correct with"))
    }

    /// A bar no shape can clear, so the winner fails its residual check and nothing is returned.
    @Test("a winner that does not describe the delays is not handed back")
    func noAdequateShape() {
        var returned: [(String, LabelClass, Double, Double)] = []
        for index in 0..<60 {
            returned.append(("loss\(index)", .loss, Double(9 + index % 9), 90))
            returned.append(("clean\(index)", .noLoss, Double(2 + index % 5), 90))
        }
        let outcome = MetadataPipeline.shapeOutcome(
            for: panel(asOf: 90, returned: returned),
            settings: SelectionSettings(adequacyCoefficient: 0)
        )
        guard case .skipped(let reason) = outcome else {
            Issue.record("expected a skip, got \(outcome)")
            return
        }
        #expect(reason.contains("fits no candidate family"))
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
        await pipeline().auditDelayShape(trace: &trace, ledger: ExplorationLedger())
        let record = trace.records.first { $0.stage == .delayShape }
        #expect(
            record?.outcome
                == .noOp(reason: "nothing has been explored yet — there are no arrival times to shape")
        )
    }

    @Test("a real ledger from this app reaches the degenerate skip")
    func realLedgerIsDegenerate() async {
        let ledger = ExplorationLedger()
        await admitted(["explore-0", "explore-1", "explore-2"], into: ledger)
        await ledger.label("explore-0", loss: 1)
        await ledger.label("explore-1", loss: 0)
        await ledger.label("explore-2", loss: 0)
        var trace = PipelineTrace()
        await pipeline().auditDelayShape(trace: &trace, ledger: ledger)
        let record = trace.records.first { $0.stage == .delayShape }
        guard case .skipped(let reason)? = record?.outcome else {
            Issue.record("expected a skip, got \(String(describing: record?.outcome))")
            return
        }
        // Three labels is below the volume gate, so this reads as too few rather than degenerate —
        // which is the correct order: three returns sharing a tick is a small sample, not a
        // process with no shape in it.
        #expect(reason.contains("no delay shape"))
    }

    @Test("admissions with no labels yet are a no-op rather than a shape of nothing")
    func admittedButUnlabelled() async {
        let ledger = ExplorationLedger()
        await admitted(["explore-0", "explore-1"], into: ledger)
        var trace = PipelineTrace()
        await pipeline().auditDelayShape(trace: &trace, ledger: ledger)
        let record = trace.records.first { $0.stage == .delayShape }
        guard case .noOp(let reason)? = record?.outcome else {
            Issue.record("expected a no-op, got \(String(describing: record?.outcome))")
            return
        }
        #expect(reason.contains("nothing has arrived to shape"))
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

    /// An `ExplorationLedger` cannot produce this, which is why the entry-list form exists.
    @Test("an entry list this app cannot produce is skipped, not crashed on")
    func unreadableLedger() async {
        var trace = PipelineTrace()
        await pipeline().auditDelayShape(
            trace: &trace,
            entries: [entry("explore-0", loss: 1), entry("explore-0", loss: 0)]
        )
        let record = trace.records.first { $0.stage == .delayShape }
        #expect(
            record?.outcome
                == .skipped(reason: "the exploration ledger could not be read as a return ledger")
        )
    }
}
