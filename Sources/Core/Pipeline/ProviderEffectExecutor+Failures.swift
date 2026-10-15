import Foundation
import IdempotencyKit
import ProviderGatewayKit

/// How a provider error is classified for the idempotency guard and the retry policy. Pure
/// functions of the error, kept beside the executor that uses them.
extension ProviderEffectExecutor {
    /// Whether the effect provably did not happen.
    ///
    /// Everything the provider rejects before streaming a byte is `.notApplied`: no tokens were
    /// billed, so the key is safe to reuse. A connection that dropped mid-stream is the genuinely
    /// ambiguous case — the upstream may have completed and charged for it — so that one stays
    /// `.indeterminate` and the guard freezes the key, which is the behaviour it exists for.
    static func failureMode(for error: ProviderError) -> FailureMode {
        switch error {
        case .rateLimited, .capabilityMismatch:
            return .notApplied
        case .timeout, .connectionFailed:
            return .indeterminate
        }
    }

    /// Only a rate limit carries a server-supplied delay. Everything else backs off on the
    /// policy's own schedule.
    static func retryHint(for error: Error) -> TimeInterval? {
        guard case let .rateLimited(retryAfter)? = error as? ProviderError,
              let retryAfter else { return nil }
        return TimeInterval(retryAfter.components.seconds)
    }
}
