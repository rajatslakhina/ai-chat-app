import ClaimSegmenterKit
import GroundingKit

/// Puts `ClaimSegmenterKit` behind the seam `GroundingKit` already has, so grounding and claim
/// consistency judge clauses instead of whole sentences.
///
/// This is the only place in the app where the unit of verification is decided. Every truthfulness
/// check downstream — grounding, citation checking, consistency — takes the claim it is handed and
/// asks whether it is true. None of them get a say in what a claim is, and until this stage existed
/// the answer was "one sentence", which is wrong the moment a sentence carries two assertions:
///
///     The response cache is enabled by default, but it is not shared across sessions.
///
/// One verdict cannot describe both halves. Whichever way it lands, it is wrong about one of them,
/// and nothing in the output says which.
///
/// **The two segmenters are complementary, not rival.** `SentenceClaimSegmenter` is still what
/// pulls `[doc-1]` markers out of a claim's text, so it runs on each clause after the cut. Only the
/// boundaries changed hands.
struct ClaimSegmenterBridge: GroundingKit.ClaimSegmenting {
    let policy: SegmentationPolicy

    init(policy: SegmentationPolicy = .default) {
        self.policy = policy
    }

    func claims(in answer: String) -> [GroundingKit.Claim] {
        let citations = SentenceClaimSegmenter()
        guard let segmented = try? SynchronousClaimSegmenter(policy: policy).segment(answer) else {
            // Nothing checkable came back. Falling through to `GroundingKit`'s own segmenter rather
            // than returning `[]`, because an empty claim list makes a verifier report a clean
            // sweep over nothing — an answer nobody checked, published as if it were verified.
            // Standing aside to the coarser segmenter loses granularity; standing aside to nothing
            // loses the check.
            return citations.claims(in: answer)
        }
        return segmented.claims.enumerated().compactMap { index, claim in
            guard let parsed = citations.claims(in: claim.verifiableText).first else { return nil }
            return GroundingKit.Claim(
                id: "c\(index + 1)",
                text: parsed.text,
                rawText: claim.text,
                citations: parsed.citations,
                span: GroundingKit.TextSpan(
                    offset: claim.span.start,
                    length: claim.span.length,
                    text: claim.text
                )
            )
        }
    }
}
