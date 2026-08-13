import AnswerabilityKit
import EvidenceSensitivityAnswerability
import EvidenceSensitivityKit
import Foundation

extension PreModelPipeline {
    /// Measures whether the answerability gate's admission would survive its own evidence
    /// being taken apart, and refuses the one case where it provably would not.
    ///
    /// The gate above this one rules on the evidence it was handed. It has no way to ask whether
    /// that ruling was *load-bearing* — whether it came from the corpus or from the particular
    /// passages retrieval happened to return this time. This app already learned that the hard
    /// way: keying lifted one side of its retry corpus from 0.75 to 1.00 while the other stayed
    /// at 0.75, and a flat contradiction became an admission. The gate was not wrong either time;
    /// it was reading a margin between two numbers, and margins move.
    ///
    /// Runs after the gate admits and before anything is spent, which is the only place it is
    /// free. Everything downstream of `providerRouting` judges a paragraph already paid for.
    func measureVerdictStability(
        of sources: [RetrievedSource],
        for outbound: String,
        trace: inout PipelineTrace
    ) async -> AnswerabilityResult {
        guard !sources.isEmpty else {
            trace.record(
                .verdictStability,
                .skipped(reason: "no retrieved passages; there is no verdict resting on evidence")
            )
            return .admitted
        }

        let probe = AnswerabilityVerdictProbe(
            engine: stabilityEngine,
            question: Question(outbound),
            corpus: sources.map { EvidenceItem(id: $0.id, text: $0.snippet) }
        )
        let report = await stability.analyse(evidence: Self.references(for: sources), using: probe)
        return Self.act(on: report, sourceCount: sources.count, trace: &trace)
    }

    /// Document identity, as far as this app can honestly claim to know it.
    ///
    /// `RetrievedSource` carries no document identifier — only `id`, `title` and `snippet` — so
    /// two chunks of one page and two separate pages are the same shape here. `title` is the
    /// closest thing to document identity the retrieval layer actually produces.
    ///
    /// The failure mode is worth stating rather than hiding: two genuinely distinct documents
    /// that share a title get merged, so this **under-reports** independence and never
    /// over-reports it. That direction is the safe one — it can route a sound answer to review,
    /// which costs a moment, and it cannot let a single-source answer pass as corroborated,
    /// which costs the user's trust. Giving `RetrievedSource` a real document identifier is the
    /// correct fix and belongs in the retrieval layer, not here.
    static func references(for sources: [RetrievedSource]) -> [EvidenceRef] {
        sources.map { EvidenceRef(id: $0.id, documentID: $0.title) }
    }

    /// Internal rather than private so every arm can be driven directly.
    ///
    /// The alternative is reaching each verdict through the real engine by choosing corpus text
    /// until the strengths land where the test needs them — which tests the matcher's vocabulary
    /// rather than this decision table, and breaks whenever the matcher improves.
    static func act(
        on report: SensitivityReport,
        sourceCount: Int,
        trace: inout PipelineTrace
    ) -> AnswerabilityResult {
        switch report.verdict {
        case .robust:
            trace.record(
                .verdictStability,
                .ran(detail: "admission survives losing any passage and any document "
                    + "(\(report.probeCount) re-runs over \(sourceCount) passage(s))")
            )
            return .admitted

        case let .coincidental(.offsettingWeakness(affirming, denying)):
            // Only a *contested* ruling can be undermined by this finding.
            //
            // Offsetting weakness says two sides landed close while neither is strong — which is
            // a statement about a conflict being coincidental. When the gate ruled `answerable`
            // there is no conflict claim to undermine, and the same numbers mean only that
            // support was thin. Refusing on them blocked "how much am I spending, what is the
            // ceiling" against this app's own budget corpus, which is the third time a wholesale
            // refusal here has turned out to be wrong for a different reason than the last.
            guard report.baseline.label == "contested" else {
                trace.record(
                    .verdictStability,
                    .ran(detail: String(format: "support %.2f against %.2f is thin on both sides, but "
                        + "the gate ruled '%@' rather than contested; recorded, not refused",
                        affirming, denying, report.baseline.label))
                )
                return .admitted
            }
            return .refused(Self.offsettingRefusal(affirming: affirming, denying: denying, trace: &trace))

        case let .coincidental(.singleDocumentCorroboration(documentID, passages)):
            // Recorded, not refused. Answering from one document is ordinary and often correct.
            // What would be wrong is presenting it as corroborated, and that is a claim this
            // stage does not make on the app's behalf either way.
            trace.record(
                .verdictStability,
                .ran(detail: "admitted on \(passages) passage(s) from one document (\(documentID)); "
                    + "agreement between them is one source, not several")
            )
            return .admitted

        case let .pivotal(items, documents):
            trace.record(
                .verdictStability,
                .ran(detail: "admission depends on \(Self.describe(items, "passage")) and "
                    + "\(Self.describe(documents, "document")); losing any of them changes the ruling")
            )
            return .admitted

        case let .knifeEdge(margin):
            trace.record(
                .verdictStability,
                .ran(detail: String(format: "admission sits %.2f from the gate's threshold; "
                    + "a rescoring flips it without any passage changing", margin))
            )
            return .admitted

        case let .undetermined(cause):
            trace.record(.verdictStability, Self.unmeasured(cause))
            return .admitted
        }
    }

    /// The one refusal this stage makes, and the reason it is the only one.
    ///
    /// Every other finding here says the admission is *fragile* — true, worth recording, and not
    /// grounds to refuse a question the corpus can answer. This one says something different: the
    /// two sides landed close enough for the gate to rule while neither is independently strong,
    /// so the ruling is two recall failures cancelling. The app cannot tell from this evidence
    /// whether its sources agree or contradict, and answering as if it could is the failure the
    /// whole truthfulness chain exists to prevent.
    private static func offsettingRefusal(
        affirming: Double,
        denying: Double,
        trace: inout PipelineTrace
    ) -> Refusal {
        let refusal = Refusal(
            stage: .verdictStability,
            headline: "Your sources are too weakly matched to rule on",
            explanation: String(
                format: "Support and contradiction scored %.2f and %.2f — close enough to look "
                    + "settled, but neither is strong on its own. That is two matching failures "
                    + "cancelling out, not agreement. Retrieving passages that use the question's "
                    + "own words would settle it.",
                affirming,
                denying
            ),
            recovery: .openSettings(field: "Retrieval")
        )
        trace.record(.verdictStability, .refused(refusal))
        return refusal
    }

    /// A refusal to measure is never an admission that measuring went fine.
    private static func unmeasured(_ cause: UndeterminedCause) -> StageOutcome {
        switch cause {
        case .emptyEvidence:
            return .skipped(reason: "no evidence to perturb")
        case let .tooFewItems(count, required):
            return .skipped(
                reason: "\(count) passage(s), \(required) needed; leave-one-out over one passage "
                    + "asks a different question than the gate answered"
            )
        case let .degenerateProbe(label):
            return .noOp(
                reason: "the gate returned '\(label)' with and without evidence, so there is no "
                    + "dependency on the corpus to measure"
            )
        }
    }

    private static func describe(_ names: [String], _ noun: String) -> String {
        names.isEmpty ? "no \(noun)" : "\(names.count) \(noun)(s)"
    }
}
