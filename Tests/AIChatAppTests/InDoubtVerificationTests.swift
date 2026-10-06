import Foundation
import ProviderGatewayKit
import Testing
import VerifiedCallKit
@testable import AIChatApp

private struct OtherError: Error {}

@Suite("Verify before retry — the rules")
struct InDoubtVerificationTests {
    @Test("OpenRouter's errors say whether an attempt may have been billed")
    func classification() {
        let classify = InDoubtVerification.classifier.classify
        #expect(classify(ProviderError.rateLimited(retryAfter: nil)) == .retryable)
        #expect(classify(ProviderError.capabilityMismatch("no tools")) == .rejected)
        #expect(classify(ProviderError.timeout) == .inDoubt)
        #expect(classify(ProviderError.connectionFailed("reset")) == .inDoubt)
        #expect(classify(URLError(.networkConnectionLost)) == .inDoubt)
        #expect(classify(URLError(.cancelled)) == .rejected)
        #expect(classify(OtherError()) == .inDoubt)
    }

    @Test("one attempt per call, one probe, and an unsettled attempt is handed back")
    func callerPolicy() {
        let policy = InDoubtVerification.caller().policy
        #expect(policy.maxAttempts == 1)
        #expect(policy.window == .immediate)
        #expect(policy.onUnresolved == .escalate)
        #expect(!policy.confirmSuccess)
    }

    @Test("each failed attempt is counted by what its verdict says")
    func summaryCounts() {
        var summary = InDoubtVerification.Summary()
        summary.absorb(.retryable("429"))
        summary.absorb(.rejected("400"))
        summary.absorb(.inDoubtUnresolved(probes: 1, reason: "no lookup"))
        summary.absorb(.cancelled)
        summary.absorb(nil)
        #expect(summary == InDoubtVerification.Summary(harmless: 2, unsettled: 1, stop: nil))
    }

    @Test("the stage outcome follows the worst thing verification saw")
    func outcomes() {
        #expect(InDoubtVerification.outcome(for: .init()) == .noOp(reason: "no attempt failed; nothing to verify"))
        #expect(InDoubtVerification.outcome(for: .init(harmless: 2)) == .ran(
            detail: "2 failed attempt(s) did no work at OpenRouter; safe to resend"
        ))
        let stop = InDoubtVerification.Stop(attempt: 1, evidence: 3, cause: "connection lost")
        let stopped = InDoubtVerification.outcome(for: .init(harmless: 1, unsettled: 1, stop: stop))
        #expect(stopped == .refused(InDoubtVerification.refusal(for: stop)))
        #expect(stopped.isRefusal)
    }

    @Test("the refusal says the answer was billed and what trying again costs")
    func refusalWording() {
        let refusal = InDoubtVerification.refusal(
            for: InDoubtVerification.Stop(attempt: 2, evidence: 5, cause: "connection lost")
        )
        #expect(refusal.stage == .verifiedCall)
        #expect(refusal.headline == "The connection dropped mid-answer")
        #expect(refusal.explanation.contains("(connection lost)"))
        #expect(refusal.explanation.contains("OpenRouter billed for it"))
        #expect(refusal.recoveryTitle == "Try again")
    }

    @Test("the probe says plainly when there is nothing to look up")
    func noLookupWording() {
        #expect("\(InDoubtVerification.NoLookup())".contains("no response bytes arrived"))
        #expect(InDoubtVerification.replayed.summary.contains("replayed"))
        #expect(InDoubtVerification.notCalled.summary.contains("before anything was sent"))
    }
}
