import Foundation
import ProviderGatewayKit
import VerifiedCallKit

/// Looks at what a failed attempt received before the retry policy is allowed to resend it.
///
/// `RetryPolicyKit` decides *when* to try again, and it treated every failure the same way. A 429
/// is OpenRouter refusing before doing any work, so resending it is free. A connection that dropped
/// while the answer was streaming is different: OpenRouter had already generated, and billed, the
/// tokens that arrived. Resending that one silently paid for the answer twice.
///
/// Each attempt now runs through a `VerifiedCaller`. Its probe is the evidence the attempt left:
///
/// - **Part of an answer arrived** (a fragment, or a completed tool-call hop): the attempt took
///   effect and was billed. It is not resent. The user gets a refusal that says so, with a Try
///   again button that sends a new, separately billed request.
/// - **Nothing arrived**: there is nothing to look up. OpenRouter's generation lookup needs the id
///   the first chunk carries, and no chunk came. The probe says it cannot answer, the attempt stays
///   in doubt, and the retry policy decides as before. The trace records that a resend may have
///   been billed twice.
/// - **Provably no work** (a 429, a rejected request): resent under the retry policy, as before.
///
/// The probe never claims an absence. It can see evidence that an attempt took effect, but not
/// proof that one did not.
enum InDoubtVerification {
    /// OpenRouter's own errors say what happened. A transport error that escaped the provider
    /// mid-stream means the request had been sent, so it is in doubt. A locally cancelled request
    /// is not checked: the user stopped it, and nothing about it should be read as a dropped answer.
    static let classifier = FailureClassifier { error in
        if (error as? URLError)?.code == .cancelled { return .rejected }
        guard let providerError = error as? ProviderError else { return .inDoubt }
        switch providerError {
        case .rateLimited: return .retryable
        case .capabilityMismatch: return .rejected
        case .timeout, .connectionFailed: return .inDoubt
        }
    }

    /// One attempt per call. The loop around it, with its backoff and `Retry-After` handling, stays
    /// `RetryPolicyKit`'s; this caller only decides whether an attempt may be resent.
    static func caller() -> VerifiedCaller {
        VerifiedCaller(
            policy: VerificationPolicy(maxAttempts: 1, window: .immediate, onUnresolved: .escalate),
            classifier: classifier
        )
    }

    /// What the probe throws when an attempt received nothing it could look up.
    struct NoLookup: Error, CustomStringConvertible {
        var description: String {
            "no response bytes arrived, and OpenRouter has no lookup without a generation id"
        }
    }

    /// An attempt that had streamed part of an answer when it failed: billed, so not resent.
    struct Stop: Sendable, Equatable {
        let attempt: Int
        /// Fragments and tool-call hops the attempt received before it failed.
        let evidence: Int
        let cause: String
    }

    /// What verification saw across one turn's attempts.
    struct Summary: Sendable, Equatable {
        /// Failed attempts that did no work at OpenRouter.
        var harmless = 0
        /// Failed attempts that were in doubt with nothing to look up.
        var unsettled = 0
        var stop: Stop?

        /// Folds in one failed attempt's verdict. A cancellation is neither: nothing is judged.
        mutating func absorb(_ verdict: AttemptVerdict?) {
            switch verdict {
            case .retryable?, .rejected?: harmless += 1
            case .inDoubtUnresolved?: unsettled += 1
            default: break
            }
        }
    }

    static func outcome(for summary: Summary) -> StageOutcome {
        if let stop = summary.stop {
            return .refused(refusal(for: stop))
        }
        if summary.unsettled > 0 {
            return .ran(
                detail: "\(summary.unsettled) failed attempt(s) were in doubt with no response bytes "
                    + "to check, so the retry policy decided; a resend may have been billed twice"
            )
        }
        if summary.harmless > 0 {
            return .ran(
                detail: "\(summary.harmless) failed attempt(s) did no work at OpenRouter; safe to resend"
            )
        }
        return .noOp(reason: "no attempt failed; nothing to verify")
    }

    static func refusal(for stop: Stop) -> Refusal {
        Refusal(
            stage: .verifiedCall,
            headline: "The connection dropped mid-answer",
            explanation: "Part of the answer had already arrived when the connection failed (\(stop.cause)), "
                + "so OpenRouter billed for it. It was not resent automatically. "
                + "Trying again starts a new answer, billed separately.",
            recovery: .retryLater(after: nil)
        )
    }

    static let replayed = StageOutcome.skipped(
        reason: "replayed an earlier result; nothing was sent, so nothing could fail in doubt"
    )

    static let notCalled = StageOutcome.skipped(
        reason: "the idempotency guard stopped the turn before anything was sent"
    )
}
