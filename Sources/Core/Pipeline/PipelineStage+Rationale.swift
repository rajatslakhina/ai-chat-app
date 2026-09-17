// The extended rationale for the gate and feedback stages: everything from
// `evidenceKeying` through `labelClock`.
//
// Split out of `PipelineStage.swift` on 2026-09-15, and split again by stage
// family on 2026-09-17 when the single file reached 495 of SwiftLint's 500
// lines and the next stage would not have fitted. Cases cannot themselves move
// — every case of an enum must live in the enum's own body — so the doc-comment
// prose above them is the only lever left. A pure text move: nothing in any of
// these files is compiled or reachable at runtime. `PipelineStage.swift` keeps a
// one-line pointer per stage; the reasoning it points to is here, keyed by case
// name.
// Siblings: `PipelineStage+RationaleMeasurement.swift` and
// `PipelineStage+RationaleTooling.swift`.

// MARK: - evidenceKeying
// Which inflectional families the answerability gate will read the evidence through.
// Produces the audit trail for the stage below it: without it, a gate that changes its
// mind about the same corpus cannot be asked why.

// MARK: - answerabilityGate
// Whether the passages that survived can answer the question that was asked.
// Runs after compaction so it judges the evidence the model will actually receive.

// MARK: - temporalValidity
// Whether the passages the gate just admitted are still entitled to speak.
// Runs before independence and stability because it needs nothing from either — only the
// dates the corpus already carried — and because a ruling that rests on an expired snapshot
// is not worth measuring the provenance of.

// MARK: - sourceIndependence
// Whether the gate's ruling would survive its own evidence being taken apart.
// Runs only after an admission, because there is no point measuring the stability of a
// verdict the app already refused to act on.
// How many independent sources are actually behind the passages the gate just admitted.
// Runs before stability, because stability's document-level pass is only as good as the
// document identifiers it is handed, and this app's retrieval layer supplies none.

// MARK: - signalDependence
// How many of the four gates above are actually separate judges.
// Runs between the gates and the arbiter because it changes what the arbiter is counting,
// not what it decides: stability re-runs the answerability gate with evidence withheld, so
// the two agreeing is one engine agreeing with itself and must not read as corroboration.

// MARK: - abstentionArbiter
// Whether the reservations the four gates above raised but did not block on add up.
// Runs last of the free stages, because it has nothing to say until they have all spoken —
// and it never overturns one of their refusals, only finds the turns none of them stopped.

// MARK: - conformalGate
// Whether this turn's readings score outside a threshold this app actually derived.
// Runs last of the free stages because it needs the reservations in their deflated form,
// and files no reservation of its own: its score is computed from the four gates above, so
// a reading of its own would be their opinion arriving twice.

// MARK: - censoredFeedback
// Whether the population the gate above was calibrated on can support its promise.
// Runs immediately before it, and is the only stage here whose effect is to stop a gate
// refusing — permitted for one reason: this app only ever learns about turns it answered,
// so a certificate computed from that log is a promise about the traffic that got through.

// MARK: - explorationChannel
// Whether to answer a turn the gate above refused, deliberately, to find out if it was right.
// Runs immediately after it and is the only stage here that overrides a *supported* refusal —
// permitted because this app labels only the turns it answered, so the refused half stays
// unmeasured forever unless something admits part of it on purpose. Structurally it can see
// no other gate's refusal: every one of them returns before this runs.

// MARK: - labelReturn
// Attaching this turn's verdict back to the admission that bought it, and saying what the
// admissions still unlabelled do to the number the gate is judged on.
//
// `explorationChannel` records that a refused turn *had a chance* and leaves its loss unknown,
// because at that point the answer does not exist. This is where the answer exists and has
// just been judged, so this is where the loop closes. It runs after the judging stages for
// that reason and not for convenience — a verdict routed before it was reached would be a
// label for a turn nobody had checked.
//
// It never refuses. An exploration whose labels are outstanding is a fact about earlier
// turns, and withholding *this* answer over it would punish the wrong request; the stages that
// could act on the finding all run before the money is spent.

// MARK: - delaySignal
// Asking whether the labels that have not come back are late or gone.
//
// `labelReturn` reports how much of the explored population is still unlabelled and brackets
// the risk accordingly, holding the bracket open for whatever those labels turn out to say.
// That is the correct move when they might still arrive. This stage measures whether they
// might — a return process whose delay depends on the outcome makes the floor optimistic in a
// way no bracket width announces, and a return process with no delay at all makes an
// outstanding label something other than a slow one.
//
// Off the critical path, after the answer is on screen, because nothing it finds is about the
// turn it runs on.

// MARK: - delayShape
// Asking whether the delay the stage above reads has any shape in it at all.
//
// `delaySignal` skips because it cannot separate the two classes by their delays. That is one
// estimator's identifiability condition. This is the more basic version: is there a delay
// *distribution* of any kind here, and if there is, is the constant hazard every correction in
// this pipeline assumes actually the right one? The two failures have different remedies, and
// only one of them is waiting for more labels.
//
// Off the critical path, beside `delaySignal`, for the same reason.

// MARK: - delayCurve
// Asking what the labels that *did* come back say, with no family in the way.
//
// `delaySignal` needs two separable rates and `delayShape` needs one of four families to fit.
// A product-limit estimate needs neither, so this stage can produce a curve where both of them
// decline — and the interesting part is that being able to produce one is not the same as
// being allowed to spend it. A survival estimate assumes the requests still outstanding are
// like the ones that returned, only later. Here they are not: they never reached a verdict.
// Nothing in the data says so, which is exactly why the stage has to.
//
// Off the critical path, beside the two above, for the same reason.

// MARK: - curveDivergence
// Comparing two classes' delay curves without reducing either to a number.
//
// `delayCurve` estimates one curve. This asks whether two of them differ, and it asks with a
// supremum rather than an area, so a crossing cannot cancel the way a restricted mean's can.
// It also reports the tick the largest gap lands on, which is the part a single summary cannot
// produce.
//
// In this app it does not get to. Every admission is timestamped `admitted 0, returned 1`, so
// the shared window is one tick wide and a supremum over one tick is a difference of two
// proportions wearing a survival test's clothes. Worse, the two classes this app could form
// differ in their *labelling* rate by construction — an explored turn is bought precisely to
// obtain a label — so the test would report a large, highly significant separation that is an
// artifact of how the arms were built rather than a fact about delay.
//
// Off the critical path, beside the three above, for the same reason.

// MARK: - labelClock
// Measuring the defect the four stages above it keep describing.
//
// `delaySignal`, `delayShape`, `delayCurve` and `curveDivergence` each decline for a reason of
// their own, and each of their reasons ends in the same place: this app records *whether a
// verdict arrived* and *what the verdict said* in one field. `curveDivergence` says so in
// prose. This stage says so in numbers, and then separates the one defect into the two it
// actually is.
//
// The first is the cohort, and it is fixable. `admissionProbability` is decided when the turn
// is admitted, so a cohort taken from it exists before any label does — and the audit reports
// how many admissions become censorable the moment the cohort stops being the outcome.
//
// The second is the clock, and it is not fixable here. Every admission is timestamped
// `admitted 0, returned 1`, so follow-up is one tick wide whatever the cohort is, and no
// landmark can fall inside it. Bundling the two together, as the four stages above do, hides
// that one of them has a remedy available today.
//
// Off the critical path with its siblings, and like them it never produces a `Refusal`: this
// is a statement about the app's own schema, not about anything the user did or can undo.
