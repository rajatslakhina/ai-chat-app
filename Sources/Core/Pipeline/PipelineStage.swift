import AbstentionPolicyKit
import Foundation

/// Every stage one user message passes through, in the order it passes through them.
///
/// One case per package in the ecosystem, which is the point: the ordering below *is* the
/// architecture, and a stage that has no case here is a package that is not really wired in.
/// `CaseIterable` lets the Diagnostics screen enumerate all of them and show which ones actually
/// ran, so a package that silently did nothing is visible as a gap rather than invisible.
enum PipelineStage: String, CaseIterable, Sendable, Identifiable {
    // Before the model sees anything
    case promptTemplate
    case guardrailInput
    case semanticRoute
    case idempotencyGuard
    case cacheLookup
    case memoryRecall
    case retrieval
    /// The lexical half of retrieval, and the fusion that reconciles it with the dense half.
    case lexicalRetrieval
    case rankFusion
    /// Whether the passages that survived fusion agree with each other.
    case sourceConflict
    case contextCompaction

    // Deciding whether the turn is allowed to happen at all
    /// Which inflectional families the answerability gate will read the evidence through.
    /// Produces the audit trail for the stage below it: without it, a gate that changes its
    /// mind about the same corpus cannot be asked why.
    case evidenceKeying
    /// Whether the passages that survived can answer the question that was asked.
    /// Runs after compaction so it judges the evidence the model will actually receive.
    case answerabilityGate
    /// Whether the passages the gate just admitted are still entitled to speak.
    /// Runs before independence and stability because it needs nothing from either — only the
    /// dates the corpus already carried — and because a ruling that rests on an expired snapshot
    /// is not worth measuring the provenance of.
    case temporalValidity
    /// Whether the gate's ruling would survive its own evidence being taken apart.
    /// Runs only after an admission, because there is no point measuring the stability of a
    /// verdict the app already refused to act on.
    /// How many independent sources are actually behind the passages the gate just admitted.
    /// Runs before stability, because stability's document-level pass is only as good as the
    /// document identifiers it is handed, and this app's retrieval layer supplies none.
    case sourceIndependence
    case verdictStability
    /// How many of the four gates above are actually separate judges.
    /// Runs between the gates and the arbiter because it changes what the arbiter is counting,
    /// not what it decides: stability re-runs the answerability gate with evidence withheld, so
    /// the two agreeing is one engine agreeing with itself and must not read as corroboration.
    case signalDependence
    /// Whether the reservations the four gates above raised but did not block on add up.
    /// Runs last of the free stages, because it has nothing to say until they have all spoken —
    /// and it never overturns one of their refusals, only finds the turns none of them stopped.
    case abstentionArbiter
    /// Whether this turn's readings score outside a threshold this app actually derived.
    /// Runs last of the free stages because it needs the reservations in their deflated form,
    /// and files no reservation of its own: its score is computed from the four gates above, so
    /// a reading of its own would be their opinion arriving twice.
    case conformalGate
    /// Whether the population the gate above was calibrated on can support its promise.
    /// Runs immediately before it, and is the only stage here whose effect is to stop a gate
    /// refusing — permitted for one reason: this app only ever learns about turns it answered,
    /// so a certificate computed from that log is a promise about the traffic that got through.
    case censoredFeedback
    /// Whether to answer a turn the gate above refused, deliberately, to find out if it was right.
    /// Runs immediately after it and is the only stage here that overrides a *supported* refusal —
    /// permitted because this app labels only the turns it answered, so the refused half stays
    /// unmeasured forever unless something admits part of it on purpose. Structurally it can see
    /// no other gate's refusal: every one of them returns before this runs.
    case explorationChannel
    case workloadProfile
    case costForecast
    case budgetReserve

    // Getting an answer
    case retryPolicy
    case providerRouting
    case streamAggregation
    case sessionDelivery

    // Making sense of the answer
    case structuredDecode
    case outputRepair
    case schemaMigration
    case grounding
    /// Deciding what a claim *is*, before anything judges one.
    case claimSegmentation
    /// Whether each grounded claim actually *agrees* with the passage it matched.
    case claimConsistency
    /// Whether each claim is supported by the document the answer *said* it came from.
    case citationBinding
    /// Whether each claim can be read on its own, or only makes sense inside the answer.
    case claimDecontextualization
    /// Attaching this turn's verdict back to the admission that bought it, and saying what the
    /// admissions still unlabelled do to the number the gate is judged on.
    ///
    /// `explorationChannel` records that a refused turn *had a chance* and leaves its loss unknown,
    /// because at that point the answer does not exist. This is where the answer exists and has
    /// just been judged, so this is where the loop closes. It runs after the judging stages for
    /// that reason and not for convenience — a verdict routed before it was reached would be a
    /// label for a turn nobody had checked.
    ///
    /// It never refuses. An exploration whose labels are outstanding is a fact about earlier
    /// turns, and withholding *this* answer over it would punish the wrong request; the stages that
    /// could act on the finding all run before the money is spent.
    case labelReturn

    /// Asking whether the labels that have not come back are late or gone.
    ///
    /// `labelReturn` reports how much of the explored population is still unlabelled and brackets
    /// the risk accordingly, holding the bracket open for whatever those labels turn out to say.
    /// That is the correct move when they might still arrive. This stage measures whether they
    /// might — a return process whose delay depends on the outcome makes the floor optimistic in a
    /// way no bracket width announces, and a return process with no delay at all makes an
    /// outstanding label something other than a slow one.
    ///
    /// Off the critical path, after the answer is on screen, because nothing it finds is about the
    /// turn it runs on.
    case delaySignal

    /// Asking whether the delay the stage above reads has any shape in it at all.
    ///
    /// `delaySignal` skips because it cannot separate the two classes by their delays. That is one
    /// estimator's identifiability condition. This is the more basic version: is there a delay
    /// *distribution* of any kind here, and if there is, is the constant hazard every correction in
    /// this pipeline assumes actually the right one? The two failures have different remedies, and
    /// only one of them is waiting for more labels.
    ///
    /// Off the critical path, beside `delaySignal`, for the same reason.
    case delayShape

    /// Asking what the labels that *did* come back say, with no family in the way.
    ///
    /// `delaySignal` needs two separable rates and `delayShape` needs one of four families to fit.
    /// A product-limit estimate needs neither, so this stage can produce a curve where both of them
    /// decline — and the interesting part is that being able to produce one is not the same as
    /// being allowed to spend it. A survival estimate assumes the requests still outstanding are
    /// like the ones that returned, only later. Here they are not: they never reached a verdict.
    /// Nothing in the data says so, which is exactly why the stage has to.
    ///
    /// Off the critical path, beside the two above, for the same reason.
    case delayCurve

    /// Comparing two classes' delay curves without reducing either to a number.
    ///
    /// `delayCurve` estimates one curve. This asks whether two of them differ, and it asks with a
    /// supremum rather than an area, so a crossing cannot cancel the way a restricted mean's can.
    /// It also reports the tick the largest gap lands on, which is the part a single summary cannot
    /// produce.
    ///
    /// In this app it does not get to. Every admission is timestamped `admitted 0, returned 1`, so
    /// the shared window is one tick wide and a supremum over one tick is a difference of two
    /// proportions wearing a survival test's clothes. Worse, the two classes this app could form
    /// differ in their *labelling* rate by construction — an explored turn is bought precisely to
    /// obtain a label — so the test would report a large, highly significant separation that is an
    /// artifact of how the arms were built rather than a fact about delay.
    ///
    /// Off the critical path, beside the three above, for the same reason.
    case curveDivergence

    /// Measuring the defect the four stages above it keep describing.
    ///
    /// `delaySignal`, `delayShape`, `delayCurve` and `curveDivergence` each decline for a reason of
    /// their own, and each of their reasons ends in the same place: this app records *whether a
    /// verdict arrived* and *what the verdict said* in one field. `curveDivergence` says so in
    /// prose. This stage says so in numbers, and then separates the one defect into the two it
    /// actually is.
    ///
    /// The first is the cohort, and it is fixable. `admissionProbability` is decided when the turn
    /// is admitted, so a cohort taken from it exists before any label does — and the audit reports
    /// how many admissions become censorable the moment the cohort stops being the outcome.
    ///
    /// The second is the clock, and it is not fixable here. Every admission is timestamped
    /// `admitted 0, returned 1`, so follow-up is one tick wide whatever the cohort is, and no
    /// landmark can fall inside it. Bundling the two together, as the four stages above do, hides
    /// that one of them has a remedy available today.
    ///
    /// Off the critical path with its siblings, and like them it never produces a `Refusal`: this
    /// is a statement about the app's own schema, not about anything the user did or can undo.
    case labelClock

    /// The declared dependence graph in `PreModelPipeline.dependenceGraph`, measured instead of
    /// trusted.
    ///
    /// That graph is load-bearing and its own doc comment says so: a guessed edge loosens the
    /// arbiter, and the arbiter is the one place in this pipeline that can stop a turn nobody else
    /// would. Two edges are declared there — `verdictStability` derives from `answerabilityGate`,
    /// and `sourceIndependence` shares an input with `temporalValidity` at `0.6`, above the `0.5`
    /// collapse threshold. Both are argued from construction and neither has ever been checked
    /// against what the four gates actually did, because until now nothing here could check one.
    ///
    /// This accumulates the four gates' readings across turns and measures their pairwise
    /// agreement, then holds the declared strengths against it. It is off the critical path with
    /// its siblings and, like them, never produces a `Refusal`: it is a statement about this app's
    /// own wiring and there is nothing in it for a user to undo.
    ///
    /// It will report `.skipped` on most installs for a long time, and that is the honest reading
    /// rather than a defect. Most turns in a chat client carry no retrieved evidence, all four
    /// gates correctly record themselves as skipped, and a turn where no gate spoke is not an
    /// observation of the panel. The stage says how many turns it is still waiting for.
    case effectiveVote
    /// Whether the label the stage above says it does not have could be derived from what
    /// happened after the answer shipped.
    ///
    /// It can. `checkConsistency` already decides, per turn, whether the answer contradicted its
    /// own sources, which is a downstream outcome arriving against the **turn**. Deriving a
    /// correctness label from it is one line. Being allowed to *use* that label is not: an
    /// outcome scoped to the turn labels all four gates at once, so any error in it is shared by
    /// every one of them, and shared label noise does not blur an error correlation the way
    /// independent noise does — it manufactures one. Pricing that requires an audited subset,
    /// which is somebody reading turns, and this app has no surface for it.
    ///
    /// So this stage derives the labels, names the regime they landed in, and reports the exact
    /// refusal that stops `effectiveVote` switching basis. It never gates, and like its metadata
    /// siblings it produces no `Refusal`.
    case proxyLabel
    /// How much of what the two stages above report is the panel, and how much is the turn count.
    ///
    /// `effectiveVote` measures a correlation for every pair of gates and publishes an interval
    /// with it. That interval comes from `EffectiveVoteKit`'s Fisher transform, which clamps to
    /// `-1...1` — the bound on *any* correlation, not the bound on one this table could have
    /// produced. Fix a pair's row and column totals and phi becomes linear in a single cell, so
    /// the attainable range closes in hard the moment those totals are lopsided. In a chat client
    /// they always are: gates fire on a small minority of turns.
    ///
    /// So this stage checks each published interval against what the margins can actually express,
    /// and turns `effectiveVote`'s "not enough turns" into a count. That refusal currently names
    /// the figure it is withholding and never says how many turns would let it publish, which is
    /// the one thing a reader can act on.
    ///
    /// It never gates, and like its metadata siblings it produces no `Refusal`: it is a statement
    /// about this app's own measurements and there is nothing in it for a user to undo.
    case sampleWidth
    /// The level the three stages above quote everything at, and none of them holds.
    ///
    /// `effectiveVote` publishes a coefficient and a 95% interval for **every pair** of the four
    /// evidence gates. `proxyLabel` bounds those readings against derived labels. `sampleWidth`
    /// prices each one against the turn count. Six pairs, three readings apiece, every one at a
    /// nominal 95% — and none of them has ever been told that five others were published beside it.
    ///
    /// Six intervals at 95% do not make a 95% page. The chance that all six cover is far below
    /// that, and the largest of the six was picked out of six candidates by the same quantity it
    /// is being quoted on. This stage corrects for the six: it counts how much of the family is
    /// dependent by construction rather than assuming that away, corrects the p-values under a
    /// procedure valid at that dependence, says what six null readings would have put at the top
    /// of the page, and re-quotes the strongest interval at the level the whole page needs.
    ///
    /// It never gates, and like its metadata siblings it produces no `Refusal`: it is a statement
    /// about this app's own measurements, and there is nothing in it for a user to undo.
    case familyError

    /// The denominator ``familyError`` had to assume, measured instead.
    ///
    /// Benjamini-Yekutieli is valid under arbitrary dependence and charges `H(m)` for it. That is
    /// the right default when the dependence cannot be seen. On this panel it can: four gates make
    /// six comparisons, twelve of the fifteen pairings among them share a gate, and the design
    /// fixes the correlation between two that do. Priced rather than assumed, the multiplier falls
    /// by roughly a factor of three.
    ///
    /// The stage also records the distinction that would otherwise have gone wrong quietly. The
    /// spectral estimators return the panel's **rank** — the number of gates every comparison is
    /// built from — and a multiplicity threshold is a statement about the family's **maximum**,
    /// whose count is a different and usually larger number. Spending the rank would loosen the
    /// threshold past what the dependence supports, so `MultiplicityBudget` refuses to be built
    /// from one and this stage quotes both.
    ///
    /// It is also the only stage in this family that has something to say on a fresh install: its
    /// correction comes from the panel's shape rather than from readings, so the effective count
    /// is knowable before a single turn has been observed.
    ///
    /// It never gates, and like its metadata siblings it produces no `Refusal`: it is a statement
    /// about this app's own measurements, and there is nothing in it for a user to undo.
    case effectiveComparison

    // Acting on the answer
    case toolAuthority
    /// The second axis beside `toolAuthority`, and in this app a measurement rather than a gate.
    ///
    /// `ToolCallContext.forTurn` stamps **every** argument `.untrusted(source:)` the moment the
    /// turn carried any retrieved passage, without asking whether the argument bytes came from one.
    /// That is a single field answering two questions — the same defect `labelClock` measured for
    /// the delay family, in a different part of the app. Content trust asks whether these bytes
    /// came out of a passage; selection trust asks whether the session that chose them had read
    /// one. They are not the same question and the field cannot hold both answers.
    ///
    /// The over-tainting has a cost the user sees. Every capability here is `maxProvenance:
    /// .modelAuthored`, so one retrieved passage denies the turn's calculator call even when its
    /// arguments appear nowhere in that passage. This stage reports how many of the turn's
    /// arguments are genuinely content-derived and how many are merely under a poisoned floor.
    ///
    /// It never gates, and that is not a hedge. `SelectionTrustKit` gates commits; every tool this
    /// app registers is read-only, and reads are inert in that package by design because a read's
    /// result leaves through the model and containing it is an egress problem. So there is nothing
    /// here for it to refuse, it says so by name, and it never loosens what `toolAuthority` decided.
    case selectionTrust
    /// The matcher `selectionTrust` depends on, audited by the ladder that replaces it.
    ///
    /// That stage answers "did this argument come from a passage" with case-folded substring
    /// containment, skipping anything under four characters — a rule its own doc comment calls the
    /// weak half of the stage. Two failures follow from it and neither is visible from inside it: a
    /// number the model wrote in digits and the passage wrote in words is missed, and a
    /// four-character coincidence is counted as evidence.
    ///
    /// This stage asks the same question with four rungs and prices what they locate in bits, so
    /// the two cases stop weighing the same. It reports where the two matchers disagree, which is
    /// the only part a reader cannot get from either stage alone.
    ///
    /// The semantic rung is deliberately not installed: this app's tool arguments are short numeric
    /// expressions, and a trigram score between `2+2` and a prose passage is noise. Like its
    /// neighbour it never gates, and it never claims an argument was *not* derived.
    case argumentAttribution
    case toolDispatch
    case agentLoop
    case batchInference
    /// Recording the finished turn as a golden-case candidate for the eval suite.
    case transcriptCapture

    // Accounting for what happened
    case guardrailOutput
    case metering
    case budgetSettle
    case tracing

}

/// What a stage did.
///
/// `refused` is deliberately distinct from `failed`. A refusal is the system working: a budget
/// that says no, a guardrail that redacts, an authority check that declines a tool. A failure is
/// the system breaking. Collapsing them into one case is how a product ends up telling a user
/// "something went wrong" when the truthful answer was "you are out of budget" — and the first
/// message is unactionable while the second is not.
enum StageOutcome: Sendable, Equatable {
    /// Ran and changed something. `detail` is shown in Diagnostics.
    case ran(detail: String)
    /// Ran and correctly did nothing — a cache miss, no tools requested, nothing to compact.
    case noOp(reason: String)
    /// Deliberately not run, because configuration or the request shape made it inapplicable.
    case skipped(reason: String)
    /// The stage said no. This MUST reach the user.
    case refused(Refusal)
    /// The stage broke.
    case failed(message: String)

    var isRefusal: Bool {
        if case .refused = self { return true }
        return false
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    /// One line for the Diagnostics list.
    var summary: String {
        switch self {
        case let .ran(detail): return detail
        case let .noOp(reason): return reason
        case let .skipped(reason): return reason
        case let .refused(refusal): return refusal.headline
        case let .failed(message): return message
        }
    }
}

/// One stage's record within a single send.
struct StageRecord: Sendable, Equatable, Identifiable {
    let stage: PipelineStage
    let outcome: StageOutcome
    /// Milliseconds this stage occupied. Measured, not estimated.
    let durationMs: Int

    var id: String { stage.rawValue }
}

/// The full record of what the packages did to one message.
///
/// This is what the Diagnostics tab renders, and it is assembled during a real send rather than
/// reconstructed afterwards — a reconstruction would be a plausible story about the run instead
/// of the run itself.
struct PipelineTrace: Sendable, Equatable {
    private(set) var records: [StageRecord] = []

    /// What each stage found but did not block on.
    ///
    /// A stage that raises a reservation and returns `.admitted` currently has nowhere to put the
    /// reservation, so it is written into a `detail` string and thrown away. Independence merging
    /// two passages, stability finding support thin on both sides, the answerability gate
    /// recording a coverage gap it does not trust its own recall to refuse on — all real, all
    /// discarded. They live here so `abstentionArbiter` can ask whether several of them together
    /// mean something none of them meant alone.
    private(set) var reservations: [AbstentionSignal] = []

    /// The exploration admission this turn was answered under, if it was.
    ///
    /// A typed field rather than something read back out of a `detail` string. The stage that
    /// admits the turn and the stage that learns the verdict are at opposite ends of the pipeline,
    /// and the id is the only thing that connects them; recovering it by parsing prose is how a
    /// label ends up attached to the wrong admission.
    private(set) var explorationID: String?

    /// The id `PanelHistoryStore` filed this turn's gate readings under, if any were filed.
    ///
    /// The same reason `explorationID` is here. The stage that records what the gates said runs
    /// before the model and the stage that learns whether the answer held up runs after it, and
    /// this id is the only thing tying the two to the same turn. Attaching an outcome to
    /// "whatever the store saw last" would be correct only until two turns overlap.
    private(set) var panelTurnID: String?

    init(records: [StageRecord] = []) {
        self.records = records
    }

    /// Note that this turn was answered as a deliberate exploration.
    mutating func noteExploration(id: String) {
        explorationID = id
    }

    /// Note which panel observation this turn's gate readings were filed as.
    mutating func notePanelTurn(id: String) {
        panelTurnID = id
    }

    mutating func record(_ stage: PipelineStage, _ outcome: StageOutcome, durationMs: Int = 0) {
        records.append(StageRecord(stage: stage, outcome: outcome, durationMs: durationMs))
    }

    /// Files one stage's reading, blocking or not.
    ///
    /// Separate from `record` rather than derived from it. A `StageOutcome` says what the stage
    /// *did*; a reading says what it *found*, and the two are not the same — `.ran` covers both a
    /// clean pass and a pass that noticed something, and collapsing them would hand the arbiter a
    /// clear signal for every stage that noticed a problem and carried on.
    mutating func reserve(_ signal: AbstentionSignal) {
        reservations.append(signal)
    }

    /// Replaces the filed readings with one per independent voice.
    ///
    /// A replacement rather than a parallel store. The arbiter must rule on exactly one array or
    /// its explanation can describe a set of findings the decision was not made from — the second
    /// source of truth this ecosystem removed by hand on 08-18, reintroduced by the back door.
    mutating func deflateReservations(to voices: [AbstentionSignal]) {
        reservations = voices
    }

    /// The first refusal, which is the one that stopped the turn.
    var refusal: Refusal? {
        for record in records {
            if case let .refused(refusal) = record.outcome { return refusal }
        }
        return nil
    }

    var failures: [StageRecord] { records.filter(\.outcome.isFailure) }

    /// Stages that never ran at all — the ones a reader of Diagnostics would otherwise have to
    /// notice by their absence.
    var unreached: [PipelineStage] {
        let seen = Set(records.map(\.stage))
        return PipelineStage.allCases.filter { !seen.contains($0) }
    }

    var totalDurationMs: Int { records.reduce(0) { $0 + $1.durationMs } }

    func outcome(for stage: PipelineStage) -> StageOutcome? {
        records.first { $0.stage == stage }?.outcome
    }
}
