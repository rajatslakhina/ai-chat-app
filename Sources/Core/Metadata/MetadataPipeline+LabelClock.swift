import ExplorationChannelKit
import Foundation
import LabelClockKit

extension MetadataPipeline {
    /// Measures the defect the four delay stages beside it describe, and splits it into two.
    ///
    /// `curveDivergence` ends its refusal with a sentence worth taking literally: *a clock with
    /// more than one tick would fix the first reason; only a label that arrives separately from the
    /// class would fix the second.* Those are two different remedies with two different costs, and
    /// as long as they are stated together in prose nobody can tell which one is available.
    ///
    /// This stage builds the same ledger twice. Once with the cohort taken from `observedLoss`,
    /// which is what all four siblings do, and once with it taken from `admissionProbability`,
    /// which is fixed the moment the turn is admitted. The two audits differ in exactly one number
    /// — how many admissions can carry a censored observation — and that number is the whole
    /// argument.
    ///
    /// It runs rather than skips because both audits are real measurements over real ledger
    /// entries, and the conclusion is a fact about this app rather than a decision it declined to
    /// make. Like its siblings it never produces a `Refusal`: this is a statement about the app's
    /// own schema and there is nothing here for a user to undo.
    func auditLabelClock(
        trace: inout PipelineTrace,
        ledger: ExplorationLedger = ExplorationBudget.ledger
    ) async {
        await auditLabelClock(trace: &trace, entries: await ledger.allEntries)
    }

    /// The same audit over an entry list, for the same reason the sibling stages take one.
    func auditLabelClock(trace: inout PipelineTrace, entries: [ExplorationEntry]) async {
        guard !entries.isEmpty else {
            trace.record(
                .labelClock,
                .noOp(reason: "nothing has been admitted yet — there is no ledger to audit")
            )
            return
        }
        guard let outcomeLedger = Self.clockLedger(entries: entries, cohort: .outcome),
            let admissionLedger = Self.clockLedger(entries: entries, cohort: .admission)
        else {
            trace.record(
                .labelClock,
                .failed(message: "the exploration ledger could not be read as an observation ledger")
            )
            return
        }
        let auditor = LedgerAuditor(settings: .standard)
        let outcome = await auditor.audit(outcomeLedger)
        let admission = await auditor.audit(admissionLedger)
        trace.record(.labelClock, Self.clockOutcome(outcome: outcome, admission: admission))
    }

    /// Which field the cohort is read out of.
    enum ClockCohort: Sendable {
        /// `observedLoss` — what the four delay stages use, and the tick it is known in is the tick
        /// the label arrived in, because there is no earlier moment at which it exists.
        case outcome
        /// `admissionProbability` — the exploration channel's own decision, fixed at admission.
        case admission
    }

    /// The same logical clock the four delay stages share: admitted at 0, resolved by 1.
    static let clockAdmittedAt = 0
    static let clockObservedThrough = 1

    /// The loss threshold `delayPanelSnapshot` splits on, so the five stages cannot disagree about
    /// which admissions are losses.
    static let clockLossThreshold = 0.5

    /// This app's exploration ledger, read as an observation ledger under one of the two cohorts.
    static func clockLedger(entries: [ExplorationEntry], cohort: ClockCohort) -> ObservationLedger? {
        var records: [ObservationRecord] = []
        for entry in entries {
            let arrival = entry.observedLoss.map { loss in
                LabelArrival(
                    at: Self.clockObservedThrough,
                    content: loss > Self.clockLossThreshold ? "loss" : "clean"
                )
            }
            records.append(
                ObservationRecord(
                    id: entry.id,
                    enrolledAt: Self.clockAdmittedAt,
                    assignment: Self.clockAssignment(entry: entry, arrival: arrival, cohort: cohort),
                    arrival: arrival,
                    observedThrough: Self.clockObservedThrough
                )
            )
        }
        return try? ObservationLedger(records)
    }

    /// The cohort, and the tick it was genuinely decided in.
    ///
    /// The `outcome` branch stamps `assignedAt` with the arrival tick rather than with admission,
    /// and that is not a convenience — it is the honest record. The class does not exist before the
    /// label lands, so backdating it to admission would assert knowledge this app never had and
    /// would make the audit report a separation that is not there.
    static func clockAssignment(
        entry: ExplorationEntry,
        arrival: LabelArrival?,
        cohort: ClockCohort
    ) -> CohortAssignment? {
        switch cohort {
        case .outcome:
            return arrival.map { CohortAssignment(cohort: $0.content, assignedAt: $0.at) }
        case .admission:
            return CohortAssignment(
                cohort: entry.admissionProbability < 1 ? "explored" : "answered",
                assignedAt: Self.clockAdmittedAt
            )
        }
    }

    /// What the two audits say together.
    ///
    /// Separated from the actor so it can be driven with audits this app cannot currently produce,
    /// which is the same reason the four sibling stages split their verdicts out.
    static func clockOutcome(outcome: ClockAudit, admission: ClockAudit) -> StageOutcome {
        .ran(detail: Self.describeClock(outcome: outcome, admission: admission))
    }

    /// The finding, in the order the two defects have to be read in.
    static func describeClock(outcome: ClockAudit, admission: ClockAudit) -> String {
        let total = outcome.table.total
        let recovered = admission.table.censorableUnits
        let phi = outcome.table.phi.map { String(format: "%.4f", $0) } ?? "undefined"
        return "cohort from observedLoss: \(outcome.verdict), phi \(phi), "
            + "\(outcome.table.censorableUnits) of \(total) admissions censorable, "
            + "\(outcome.clocks.simultaneousCount) of \(outcome.clocks.pairedUnits) classified in "
            + "the same tick the label landed. Cohort from admissionProbability, fixed at "
            + "admission: \(admission.verdict), \(recovered) of \(total) censorable. "
            + Self.clockRemainder(recovered: recovered)
    }

    /// What is left after the cohort is fixed, and why this stage still cannot hand anything on.
    ///
    /// Two sentences that have to stay separate. The first is the clock, and no cohort repairs it.
    /// The second is that the admission-time cohort this app happens to own is confounded with the
    /// thing being measured, so recovering the censoring makes the *schema* right without making
    /// the comparison valid — and a stage that reported the first number without the second would
    /// be handing on a green light it has not earned.
    static func clockRemainder(recovered: Int) -> String {
        guard recovered > 0 else {
            return "Nothing became censorable, so the cohort is not the only thing wrong with this "
                + "ledger and the four delay stages beside this one would decline on the same "
                + "entries whichever field they split on."
        }
        return "So the cohort defect has a remedy available today and the four delay stages beside "
            + "this one are declining for a reason that is fixable. Two things stop that being a "
            + "green light. The clock is one tick wide — admitted 0, returned 1 — so no landmark "
            + "falls inside it and the follow-up carries no delay to analyse whatever the cohort "
            + "is. And the only admission-time cohort this app owns is whether the turn was "
            + "explored, which is bought precisely to obtain a label, so its labelling rate "
            + "differs from the other arm's by construction. Recovering \(recovered) censorable "
            + "admissions makes the schema right without making the comparison valid."
    }
}
