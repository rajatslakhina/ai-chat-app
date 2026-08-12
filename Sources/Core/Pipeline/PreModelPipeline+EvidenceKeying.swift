import Foundation
import MorphologyMatchKit

extension PreModelPipeline {
    /// Records which inflectional families the gate below will read this turn's evidence through.
    ///
    /// This stage decides nothing. It exists because the stage under it changed its mind: the
    /// answerability gate now reads evidence through `MorphologyEvidenceMatcher`, so a question
    /// about `requests` that were `retried` matches a passage saying a client `retries` a
    /// `request`. That is a better verdict, and an unexplained better verdict is still
    /// unexplained. **A gate whose recall can silently change is a gate nobody can audit**, and
    /// the trace is the only place a Diagnostics reader can see what was merged on their behalf.
    ///
    /// Free work, so it belongs in `PreModelPipeline`: string transforms over passages already in
    /// memory, no provider involved.
    ///
    /// `ConflationLedger` is deliberately **not** used here. It is an actor built for aggregating
    /// across turns, and its own documentation says it stays off the matching path — taking an
    /// actor hop once per turn to compute what a local dictionary computes synchronously would
    /// contradict the reason it is shaped that way.
    func recordEvidenceKeying(
        of sources: [RetrievedSource],
        for outbound: String,
        trace: inout PipelineTrace
    ) {
        guard !sources.isEmpty else {
            // Same reasoning as the gate's `.noEvidenceOffered` arm: most turns in a chat client
            // carry no passages, and that is inapplicable rather than inconclusive.
            trace.record(.evidenceKeying, .skipped(reason: "no retrieved passages; nothing to key"))
            return
        }

        let normalizer = MorphologyNormalizer()
        var surfacesByKey: [String: Set<String>] = [:]
        var refused = 0
        for conflation in Self.conflations(in: sources, and: outbound, using: normalizer) {
            surfacesByKey[conflation.key, default: []].insert(conflation.surface)
            if conflation.wasRefused { refused += 1 }
        }

        let merged = surfacesByKey.filter { $0.value.count > 1 }
        guard !merged.isEmpty else {
            // The honest outcome when the corpus and the question happen to agree on spelling.
            // Reporting `.ran` here would claim credit for work that changed nothing.
            trace.record(
                .evidenceKeying,
                .noOp(reason: "no inflectional variants across \(sources.count) passage(s); "
                    + "the gate reads the same text either way")
            )
            return
        }

        trace.record(.evidenceKeying, .ran(detail: Self.detail(merged: merged, refused: refused)))
    }

    /// Both sides of what the gate will compare: the question and every passage.
    ///
    /// The question is included because a family existing only inside the corpus changes no
    /// verdict — a merge matters when it joins something the user typed to something a passage
    /// said.
    private static func conflations(
        in sources: [RetrievedSource],
        and outbound: String,
        using normalizer: MorphologyNormalizer
    ) -> [Conflation] {
        var all = normalizer.normalize(outbound).conflations
        for source in sources {
            all += normalizer.normalize(source.snippet).conflations
        }
        return all
    }

    /// Names the widest families rather than counting them.
    ///
    /// A count tells a reader that recall was raised; the surfaces tell them whether it was raised
    /// correctly. Two forms of one verb is the matcher working, and two unrelated words sharing a
    /// key is a precision bug — and only the second reading is worth having a trace for.
    private static func detail(merged: [String: Set<String>], refused: Int) -> String {
        let widest = merged
            .sorted { lhs, rhs in
                lhs.value.count == rhs.value.count ? lhs.key < rhs.key : lhs.value.count > rhs.value.count
            }
            .prefix(3)
            .map { "\($0.key) <- \($0.value.sorted().joined(separator: "/"))" }
        return "\(merged.count) family(ies) merged: \(widest.joined(separator: ", ")); "
            + "\(refused) conflation(s) refused"
    }
}
