// The extended rationale for the measurement stages: everything from
// `effectiveVote` onward, which judge readings rather than turns.
//
// Split out of `PipelineStage.swift` on 2026-09-15, and split again by stage
// family on 2026-09-17 when the single file reached 495 of SwiftLint's 500
// lines and the next stage would not have fitted. Cases cannot themselves move
// — every case of an enum must live in the enum's own body — so the doc-comment
// prose above them is the only lever left. A pure text move: nothing in any of
// these files is compiled or reachable at runtime. `PipelineStage.swift` keeps a
// one-line pointer per stage; the reasoning it points to is here, keyed by case
// name.
// Siblings: `PipelineStage+Rationale.swift` and
// `PipelineStage+RationaleTooling.swift`.

// MARK: - effectiveVote
// The declared dependence graph in `PreModelPipeline.dependenceGraph`, measured instead of
// trusted.
//
// That graph is load-bearing and its own doc comment says so: a guessed edge loosens the
// arbiter, and the arbiter is the one place in this pipeline that can stop a turn nobody else
// would. Two edges are declared there — `verdictStability` derives from `answerabilityGate`,
// and `sourceIndependence` shares an input with `temporalValidity` at `0.6`, above the `0.5`
// collapse threshold. Both are argued from construction and neither has ever been checked
// against what the four gates actually did, because until now nothing here could check one.
//
// This accumulates the four gates' readings across turns and measures their pairwise
// agreement, then holds the declared strengths against it. It is off the critical path with
// its siblings and, like them, never produces a `Refusal`: it is a statement about this app's
// own wiring and there is nothing in it for a user to undo.
//
// It will report `.skipped` on most installs for a long time, and that is the honest reading
// rather than a defect. Most turns in a chat client carry no retrieved evidence, all four
// gates correctly record themselves as skipped, and a turn where no gate spoke is not an
// observation of the panel. The stage says how many turns it is still waiting for.

// MARK: - proxyLabel
// Whether the label the stage above says it does not have could be derived from what
// happened after the answer shipped.
//
// It can. `checkConsistency` already decides, per turn, whether the answer contradicted its
// own sources, which is a downstream outcome arriving against the **turn**. Deriving a
// correctness label from it is one line. Being allowed to *use* that label is not: an
// outcome scoped to the turn labels all four gates at once, so any error in it is shared by
// every one of them, and shared label noise does not blur an error correlation the way
// independent noise does — it manufactures one. Pricing that requires an audited subset,
// which is somebody reading turns, and this app has no surface for it.
//
// So this stage derives the labels, names the regime they landed in, and reports the exact
// refusal that stops `effectiveVote` switching basis. It never gates, and like its metadata
// siblings it produces no `Refusal`.

// MARK: - sampleWidth
// How much of what the two stages above report is the panel, and how much is the turn count.
//
// `effectiveVote` measures a correlation for every pair of gates and publishes an interval
// with it. That interval comes from `EffectiveVoteKit`'s Fisher transform, which clamps to
// `-1...1` — the bound on *any* correlation, not the bound on one this table could have
// produced. Fix a pair's row and column totals and phi becomes linear in a single cell, so
// the attainable range closes in hard the moment those totals are lopsided. In a chat client
// they always are: gates fire on a small minority of turns.
//
// So this stage checks each published interval against what the margins can actually express,
// and turns `effectiveVote`'s "not enough turns" into a count. That refusal currently names
// the figure it is withholding and never says how many turns would let it publish, which is
// the one thing a reader can act on.
//
// It never gates, and like its metadata siblings it produces no `Refusal`: it is a statement
// about this app's own measurements and there is nothing in it for a user to undo.

// MARK: - familyError
// The level the three stages above quote everything at, and none of them holds.
//
// `effectiveVote` publishes a coefficient and a 95% interval for **every pair** of the four
// evidence gates. `proxyLabel` bounds those readings against derived labels. `sampleWidth`
// prices each one against the turn count. Six pairs, three readings apiece, every one at a
// nominal 95% — and none of them has ever been told that five others were published beside it.
//
// Six intervals at 95% do not make a 95% page. The chance that all six cover is far below
// that, and the largest of the six was picked out of six candidates by the same quantity it
// is being quoted on. This stage corrects for the six: it counts how much of the family is
// dependent by construction rather than assuming that away, corrects the p-values under a
// procedure valid at that dependence, says what six null readings would have put at the top
// of the page, and re-quotes the strongest interval at the level the whole page needs.
//
// It never gates, and like its metadata siblings it produces no `Refusal`: it is a statement
// about this app's own measurements, and there is nothing in it for a user to undo.

// MARK: - effectiveComparison
// The denominator ``familyError`` had to assume, measured instead.
//
// Benjamini-Yekutieli is valid under arbitrary dependence and charges `H(m)` for it. That is
// the right default when the dependence cannot be seen. On this panel it can: four gates make
// six comparisons, twelve of the fifteen pairings among them share a gate, and the design
// fixes the correlation between two that do. Priced rather than assumed, the multiplier falls
// by roughly a factor of three.
//
// The stage also records the distinction that would otherwise have gone wrong quietly. The
// spectral estimators return the panel's **rank** — the number of gates every comparison is
// built from — and a multiplicity threshold is a statement about the family's **maximum**,
// whose count is a different and usually larger number. Spending the rank would loosen the
// threshold past what the dependence supports, so `MultiplicityBudget` refuses to be built
// from one and this stage quotes both.
//
// It is also the only stage in this family that has something to say on a fresh install: its
// correction comes from the panel's shape rather than from readings, so the effective count
// is knowable before a single turn has been observed.
//
// It never gates, and like its metadata siblings it produces no `Refusal`: it is a statement
// about this app's own measurements, and there is nothing in it for a user to undo.

// MARK: - observedNull
// Whether the distribution `effectiveComparison` draws its threshold from is one this
// panel could have produced.
//
// Its sibling corrects the family for the dependence panel geometry implies, and spends a
// Gaussian copula fitted to that structure. Two things ride underneath: that the family's
// null is Gaussian, and that a correlation of one half is reachable for gates with these
// agreement rates. Both are checkable once the panel has graded anything, and this stage
// checks them by resampling the grades instead of modelling them.
//
// It is deliberately the quieter of the two on a fresh install. `effectiveComparison` knows
// its answer from the shape alone; this one cannot, because the shape is the assumption it
// exists to test. Like its metadata siblings it produces no `Refusal`: it reports on this
// app's own measurements, and there is nothing in it for a user to undo.

// MARK: - chanceAgreement
// Whether any individual pair on that panel agrees more than its own gates' rates explain.
//
// Its three siblings above all sit on a chance term, and none of them names it. There is
// more than one candidate and they disagree: Cohen holds each gate's own affirm-rate fixed,
// Scott treats the two gates as interchangeable, Bennett keeps neither rate. Each is the
// exact mean of a resampling scheme, so choosing between them is choosing an assumption,
// and this stage states the one it spends instead of implying it.
//
// It also reports the thing a coefficient cannot: unequal affirm-rates cap that coefficient
// below one before either gate has said anything, and the shortfall against one is then the
// panel's rather than the gates'.
//
// Like its metadata siblings it produces no `Refusal`: it reports on this app's own
// measurements, and there is nothing in it for a user to undo.

// MARK: - panelDesign
// Whether the **fixture** those five readings are computed over can carry what they measure.
//
// Every stage above prices something about how much two gates agree, and all of them price
// it over the same grid of which gate affirmed which turn. None of them asks whether that
// grid can hold an association at all. It frequently cannot: two gates whose affirm-rates
// are far apart are forced to agree on a fixed share of turns before either has spoken, a
// gate that affirmed every turn pins the rate to the other gate's marginal outright, and a
// pair whose joint counts are the products of their marginals has an association of exactly
// nil rather than of nearly nil.
//
// It is the only stage here that reports on the panel rather than on the gates, which is
// why it runs last among them. Like its metadata siblings it produces no `Refusal`: nothing
// in it is a decision a user could undo.

// MARK: - squareDesign
// Which agreement counts the gates' **three-way** verdicts can reach, and which they cannot.
//
// `panelDesign` audits the affirm grid — every verdict collapsed to affirmed or not — because
// that is the basis its five siblings measure on. The gates do not cast two-way verdicts.
// They affirm, deny or abstain, and the collapse throws the third case away before anything
// looks at it. On the square panel the discarded case restores, two questions become
// answerable that were not: **which counts inside the attainable range no panel reaches**,
// and what a fixture built to a target agreement on these same verdict rates would look like.
//
// `PanelDesignKit` prices the range at every category count and then declines both: above two
// categories `admits(count:)` returns `nil` and its builder throws. The general case is a
// transportation problem with a forbidden diagonal and a prescribed trace, and it has a closed
// form — a per-category floor on the diagonal, summed against the target. This stage is that
// closed form applied to the panel this app actually accumulated.
//
// Like its metadata siblings it produces no `Refusal`: it reports on this app's own
// measurements, and there is nothing in it for a user to undo.

// MARK: - associationFit
// Which of that panel's cells the target agreement rate never chose.
//
// `squareDesign` repairs a fixture to a target **agreement rate**. On a three-way panel that
// pins one number out of nine, and its construction reaches a diagonal by pushing mass into
// corners — so the association a repaired fixture carries is an artefact of the method rather
// than a decision anybody took. Every coefficient the stages above publish is sensitive to
// the eight cells nobody chose.
//
// This stage states the association and lets the agreement rate follow, fitting a control
// structure onto the gates' own verdict rates by iterative proportional fitting — which moves
// the margins and provably cannot move the odds ratios, because row and column scalings
// cancel out of every one of them. It then prices the step every fixture in this app
// eventually takes: **a fit is real-valued and a panel is made of whole turns, and the
// margins survive that exactly while the association does not.**
//
// Like its metadata siblings it produces no `Refusal`: it reports on this app's own
// measurements, and there is nothing in it for a user to undo.

// MARK: - associationTransport
// The structure `associationFit` designs, measured on the panel this app actually has.
//
// That stage states an association and fits it onto the gates' own verdict **margins**. A
// margin says how often each gate said each thing; an association lives in how often they
// said them **together**, and nothing in this app has ever built the joint table that holds
// that. So every structure the stages above reason about is one somebody chose, and the one
// the panel already carries has never been read.
//
// This stage cross-tabulates a pair of gates and reads it. Two things come out that a
// designed structure cannot have. The first is a decision: a count of zero means either
// "these gates cannot produce this pair" or "they have not yet", the arithmetic cannot tell
// them apart, and the two readings give different structures — one of which cannot be seeded
// at all when a whole verdict category is empty, which on this panel it is.
//
// The second is an interval. A local odds ratio read off a real panel is an estimate, and
// this app's panel is small. **A block whose interval covers `1.0` is one the panel cannot
// distinguish from independence**, and reporting a structure without saying which of its
// blocks are in that state is reporting noise with a decimal point on it.
//
// Like its metadata siblings it produces no `Refusal`: it reports on this app's own
// measurements, and there is nothing in it for a user to undo.

// MARK: - exactAssociation
// What the intervals `associationTransport` reports were worth.
//
// That stage puts a **Woolf** interval around every block of the joint table: the log odds
// ratio plus or minus `1.96` standard errors, where the error is the square root of the
// summed reciprocals of four counts. It is the standard choice in the applied literature and
// it is **asymptotic** — a normal approximation on the log scale, valid in the limit of large
// counts. This panel is a few dozen turns with empty cells in it, which is precisely the
// regime where that approximation is known to be poor, and nothing in this app has ever said
// by how much.
//
// Conditioning a two-by-two block on **all four** of its margins removes every nuisance
// parameter and leaves the odds ratio alone, over a finite support. Probabilities can then be
// summed rather than approximated, and two things come out that the asymptotic side cannot
// produce. The first is that some blocks have **no odds ratio at all**: a zero margin
// determines the block's counts, so an interval reported for it is fiction rather than an
// approximation, and the stage above reached one only by adding half an item to cells nobody
// landed in. The second is a direction — swept over every small table, the exact interval is
// never the narrower of the two, so the asymptotic reading does not err in both directions
// here, it errs toward confidence.
//
// Like its metadata siblings it produces no `Refusal`: it reports on this app's own
// measurements, and there is nothing in it for a user to undo.

// MARK: - conditioningCost
// What `exactAssociation`'s exactness is conditional on, and how often the condition fails.
//
// That stage's interval is exact because it conditions on all four margins of the block,
// which removes the nuisance parameter and leaves a distribution over a finite support. The
// move is free under exactly one of the three designs a two-by-two table can arise from: the
// one that fixed both margins in advance. This panel fixed neither. Each turn is judged by
// two gates, no margin is chosen before the data arrive, and the design is total-fixed.
//
// The difference is measurable rather than arguable, because coverage is a finite sum over
// the tables a design can produce and those can be enumerated. Two things come out. The
// **exact interval over-covers**: it delivers more than the 95% it claims, and the excess is
// width a reader paid for without being told. And its guarantee is **conditional on the block
// being readable at all** — a table with a zero margin has no odds ratio, the exact side
// declines it, and a declined table is not a covered one. On a sparse panel that condition
// fails often enough that the exact interval's unconditional coverage falls below its own
// claim while its coverage among tables it read stays above it. Both numbers are correct and
// this app had no way to say either.
//
// Like its metadata siblings it produces no `Refusal`: it reports on this app's own
// measurements, and there is nothing in it for a user to undo.

// MARK: - unconditionalExact
// The same question `exactAssociation` asks, without the assumption `conditioningCost` priced.
//
// Fisher's interval is exact because it conditions on all four margins, which removes the
// nuisance parameter. That is free only when the design fixed those margins, and the previous
// stage measured what it costs here when they were not. Barnard's test keeps the parameter and
// maximises the null probability over it instead, so its guarantee is about a design rather
// than about a table.
//
// It is honest about which design. A panel of turns cross-classified by two gates is
// total-fixed; the reading here is the row-fixed one `conditioningCost` already prices, taken
// from the size side rather than the coverage side. The stage says so in its own detail rather
// than letting the reader assume the guarantee reaches further than it does.
//
// It also reports the width of the bracket its p-value is known to. Every method of this kind
// maximises on a grid, and a grid maximum is a lower bound on a supremum, so quoting one as a
// p-value errs towards rejecting. The grid is laid out so that the remainder is an arithmetic
// fact, and the caller names the precision rather than a subinterval count.

// MARK: - totalFixedExact
// The parameter `unconditionalExact` left out, and the design this panel actually has.
// Barnard's test keeps the one nuisance parameter a *row-fixed* design leaves. A panel of
// turns cross-classified by two gates fixes neither margin, so its null leaves **two** and
// the honest supremum is over a square — the gap the previous stage names and does not close.
// Reading the panel as row-fixed anyway is not conservative in either direction, so this
// stage measures which way on the block it has. Like its siblings it raises no `Refusal`.

// MARK: - confidenceSequence
// The reading `sequentialBound` structurally cannot produce, off the same pooled stream.
//
// An SPRT needs two hypotheses named in advance and answers only which of the two the evidence
// favours. It never says what the rate *is*. This stage replays the identical stream of cast
// gate verdicts through Robbins' beta-mixture martingale and publishes an interval: the set of
// pass rates the evidence has not yet ruled out. No pair of hypotheses is required, and the
// advertised rate the boundary tests toward becomes a reference the interval can simply be
// asked about — still admissible, or excluded, and at which trial it stopped being admissible.
//
// The two rates are taken from `sequentialBound` rather than invented, and that is the point of
// putting them side by side: the same healthy and degraded readings, one stage deciding between
// them and one stage measuring where the truth plausibly lies. A number invented here would make
// the comparison a comparison of two configurations instead of two methods.
//
// Why re-looking is free. A fixed-sample interval — Clopper-Pearson, say — is exact at the one
// sample size it was built for. This pipeline recomputes after every turn, and each of those
// looks spends the whole budget again, so a Clopper-Pearson band re-read every turn does not
// cover at the rate printed on it. Ville's inequality bounds the probability that the mixture
// martingale *ever* reaches `1 / alpha` by `alpha`, for the entire sequence at once, so the
// budget is spent once for all looks however many are taken.
//
// It audits itself, which is the habit this stage family already has. `ExclusionSolver`
// enumerates the whole reachable lattice rather than sampling it, and the same call answers two
// questions depending on what it is handed: with the reference rate as the truth the answer is
// this construction's exact miscoverage over the looks actually taken, and with the degraded
// rate as the truth it is the probability those same looks would have caught the degradation.
// Ville's bound is an inequality, so the first number is the slack, not the promise — and the
// slack is what the interval's width costs.
//
// Like every sibling in this pipeline it raises no `Refusal`. It reports on this app's own
// measurements after the answer has shipped; there is nothing in it for a user to undo.

// MARK: - sequentialContrast
// The question the three stages above it were structurally unable to ask.
//
// `repeatedSuccess`, `sequentialBound` and `confidenceSequence` all pool the panel into one
// stream and ask about one rate. That pooling is not a summary, it is a loss: it discards which
// gate cast which verdict on which turn. And the thing a panel is actually useful for is the
// comparison — whether two gates admit at genuinely different rates, which is a *difference*,
// and a difference is a statement about exactly the information pooling throws away.
//
// So this stage re-reads the same verdicts paired instead. Two gates, the turns both ruled on,
// side by side. `SequentialContrastKit` then puts a time-uniform interval on the difference two
// ways: once using the pairing, and once with the pairing discarded, which is what a comparison
// that only recorded two admit counts would have produced.
//
// The reason both are published, rather than only the better one, is that the gap between them
// is the finding. The unpaired construction's bounds are a Minkowski difference of two per-gate
// intervals, so it *cannot* exclude zero while those intervals overlap — an identity, not a
// conservative choice — and two gates in this app's panel overlap almost always. Reporting only
// the paired number would let a reader assume the two agree; reporting both shows that one of
// them was never able to disagree.
//
// It runs in `MetadataPipeline`, after `confidenceSequence`, for the same three reasons that one
// does: it reads turns that are already over, it costs no provider call, and the answer it
// produces is about this app's own measurements rather than about the turn in flight.
//
// A turn where either gate abstained is dropped rather than counted as agreement, and the count
// of dropped turns is reported. An abstention is not a verdict — the same distinction
// `PanelHistoryStore` already draws — and pairing one against a cast verdict would manufacture a
// disagreement nobody expressed.
//
// Like its metadata siblings it raises no `Refusal`, and that is correct rather than a gap: it
// reports on measurements taken after the answer was paid for and shipped, and there is nothing
// in it a user could undo.
//
// Its audit ceiling is 30 where `confidenceSequence`'s is 60, because that stage's exact solver
// walks an O(horizon^2) lattice and this one's walks O(horizon^3). The detail line always names
// the horizon audited alongside the turns actually paired, so a capped audit is never reported
// as an uncapped one.

// MARK: - splitContrast
//
// `SplitContrastKit` compares two arms under a randomised split: each arrival is routed to one
// arm with a known probability, and a time-uniform interval is put on the difference of their
// pass rates from the randomisation rather than from any pairing. This app has exactly one
// randomised split, and it is not a comparison of two answering systems. The exploration channel
// admits an eligible refused turn with probability `ExplorationBudget.frequency` and leaves the
// rest refused, which means the second arm is never answered and has no pass rate at all.
//
// So the difference half of the package has nothing honest to read here, and the stage says so
// in its detail rather than inventing a second arm. What it does have is the assumption the
// whole package rests on: that the split routes at the declared probability. Every
// inverse-probability weight `censoredFeedback` applies to an explored turn is
// `1 / ExplorationBudget.frequency`, so the channel's draw delivering that frequency is not a
// detail — it is the thing those weights are wrong without. The package's anytime-valid
// sample-ratio-mismatch check reads the draws `ExplorationDrawLog` keeps (the ledger keeps
// admissions only, by design) and reports whether 0.20 is still admissible, the draw it first
// stopped being, and whether the latest look re-admits it.
//
// It runs in `MetadataPipeline`, after `sequentialContrast`, for the reasons its neighbours do:
// it reads draws from turns already over, it costs no provider call, and it reports on this
// app's own machinery rather than on the turn in flight. It raises no `Refusal`. A mismatch is
// news about the channel, not about the user's turn, and there is nothing in it a user could
// undo.

// MARK: - promptCache
//
// `PromptCacheKit` audits whether a run of prompts leaves a provider's prefix cache anything to
// match: a cache hit needs a byte-identical prefix, so one message that changes on every request
// switches the cache off for everything behind it. This app resends the whole conversation on
// every turn, which is exactly the shape the package is written for, and it sets no cache markers
// itself, so the only caching it can benefit from is a provider that matches a prefix on its own.
//
// It runs in `MetadataPipeline`, after `splitContrast`, because it reads requests that are already
// over: it costs no provider call, it changes nothing that was sent, and what it finds is about
// the conversation's layout rather than the turn in flight. It does not belong before the model.
// A pre-model stage that reordered the prompt to keep the prefix stable would be a behaviour
// change to what the model sees, which is a different piece of work from finding out whether the
// current layout has a problem, and this stage does only the second.
//
// The prompts are the ones the app *sent*, not ones rebuilt from the stored conversation. The
// system message is the instructions plus whatever memory and retrieved excerpts that turn found,
// and compaction can rewrite earlier turns, so a stored transcript would describe a prompt no
// provider received. `SentPrompt` keeps each request the provider reported usage for and nothing
// else: a cache hit, a refusal and a replayed idempotent result all reach the end of a turn without
// one having left the device, so a prompt built for them would be a request nobody made.
//
// The layout is read as sent. The system message is declared `frozen`, the newest user message
// `ephemeral` and the turns between them `turn`. The system message is rebuilt every turn with
// whatever retrieval found, so declaring it stable and letting the audit report it changing is
// the honest way to ask whether it is.
//
// It also checks the layout against what the provider reported. `OpenRouterUsage` records
// `cachedPromptTokens` for every call and this is the first stage to read it. The layout predicts
// a read in estimated tokens, so it is scaled by the ratio of the later request's reported prompt
// size to its estimate, and zeroed below the policy's minimum or past its lifetime. Two limits are
// stated in the detail rather than hidden: `OpenRouterUsage` stores `0` both for a provider that
// cached nothing and for one that omitted the field, so a zero where the layout allowed a hit is
// reported as its own count instead of as the provider reading less; and the first call of a turn
// is the one compared, because a turn that called a tool records a later hop whose prompt includes
// the tool's result.
//
// Outcomes: `.skipped` when no request has a provider-reported usage, `.noOp` when fewer than two
// requests share a model or no earlier prompt reaches the cacheable minimum, and `.ran` otherwise.
// There is no `.failed` arm, and that is not an omission: nothing the stage constructs can throw,
// because the policy is a preset and the audit is total. An arm that could never be taken would
// only be a place for a test to lie.
//
// Like its metadata siblings it raises no `Refusal`. A prompt layout is not something the user did
// or can undo, the request it describes was already sent and paid for, and there is no action a
// banner could offer that would change it. The one refusal this could ever justify would stop a
// send to protect a cache, which would trade the answer the user asked for against a discount.

// MARK: - compactionPlan
//
// `CompactionPlannerKit` replays a conversation under a compaction schedule against a model of a
// provider's prompt cache, and compares schedules on price while holding the history they keep
// fixed. This app already has a schedule: `PreModelPipeline.compactIfNeeded` compacts to the whole
// window, `contextWindowTokens - reservedResponseTokens`, whenever the assembled prompt overflows
// it, which is a sliding window. Nothing had ever asked what that schedule costs in cache terms.
//
// The stage replays the requests this conversation actually sent, the same `SentPrompt` run the
// `promptCache` stage reads, under that schedule, and asks the planner two questions: does any
// schedule keep at least as much history for less, and what would giving up the last tenth of the
// kept history save. Each request's arrival is what it added: the non-system messages not in the
// request before it, compared as a multiset, so a compaction that dropped old turns from the
// request does not read as the conversation shrinking. A request that added nothing (a retry
// resends the same messages) counts as one token, the smallest arrival the package accepts, so it
// still counts as a request and its timing still decides whether the cache had lapsed.
//
// It runs in `MetadataPipeline`, after `promptCache`, for the same reasons: it reads requests that
// were already sent and paid for, costs no provider call, and changes nothing that was sent. That
// last part is a decision and not a gap. The package's own demo measured that the cheaper
// schedules keep less history, and against a sliding window at the full budget that is true by
// construction: the window keeps the longest history that fits on every request, so any cheaper
// drop-oldest schedule keeps less. Trading history the model sees for a smaller bill is a quality
// call for the owner, not a cache optimisation the app should make on its own.
//
// Outcomes: `.skipped` when no request has provider usage on record, `.noOp` when fewer than two
// requests share the latest model or when the schedule compacted nothing (the common case with a
// 128,000-token window), `.failed` when the requests cannot be replayed as a conversation (a
// request dated before the one ahead of it, as a clock set backwards produces), and `.ran`
// otherwise. Prices come from an illustrative preset, so the detail reports percentages only.
//
// It raises no `Refusal`. A compaction schedule is not something the user did or can undo.
