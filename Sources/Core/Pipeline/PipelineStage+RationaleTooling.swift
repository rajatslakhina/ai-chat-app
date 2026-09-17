// The extended rationale for the tool-argument stages: `selectionTrust` and
// `argumentAttribution`.
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
// `PipelineStage+RationaleMeasurement.swift`.

// MARK: - selectionTrust
// The second axis beside `toolAuthority`, and in this app a measurement rather than a gate.
//
// `ToolCallContext.forTurn` stamps **every** argument `.untrusted(source:)` the moment the
// turn carried any retrieved passage, without asking whether the argument bytes came from one.
// That is a single field answering two questions — the same defect `labelClock` measured for
// the delay family, in a different part of the app. Content trust asks whether these bytes
// came out of a passage; selection trust asks whether the session that chose them had read
// one. They are not the same question and the field cannot hold both answers.
//
// The over-tainting has a cost the user sees. Every capability here is `maxProvenance:
// .modelAuthored`, so one retrieved passage denies the turn's calculator call even when its
// arguments appear nowhere in that passage. This stage reports how many of the turn's
// arguments are genuinely content-derived and how many are merely under a poisoned floor.
//
// It never gates, and that is not a hedge. `SelectionTrustKit` gates commits; every tool this
// app registers is read-only, and reads are inert in that package by design because a read's
// result leaves through the model and containing it is an egress problem. So there is nothing
// here for it to refuse, it says so by name, and it never loosens what `toolAuthority` decided.

// MARK: - argumentAttribution
// The matcher `selectionTrust` depends on, audited by the ladder that replaces it.
//
// That stage answers "did this argument come from a passage" with case-folded substring
// containment, skipping anything under four characters — a rule its own doc comment calls the
// weak half of the stage. Two failures follow from it and neither is visible from inside it: a
// number the model wrote in digits and the passage wrote in words is missed, and a
// four-character coincidence is counted as evidence.
//
// This stage asks the same question with four rungs and prices what they locate in bits, so
// the two cases stop weighing the same. It reports where the two matchers disagree, which is
// the only part a reader cannot get from either stage alone.
//
// The semantic rung is deliberately not installed: this app's tool arguments are short numeric
// expressions, and a trigram score between `2+2` and a prose passage is noise. Like its
// neighbour it never gates, and it never claims an argument was *not* derived.
