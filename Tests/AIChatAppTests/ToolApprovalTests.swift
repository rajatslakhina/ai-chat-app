import Foundation
import Testing
import ToolAuthorityKit
import ToolRegistryKit
@testable import AIChatApp

/// The signature round trip: refuse, sign, resend, run.
///
/// The behaviour under test is the one the digest makes possible — an approval binds to *what the
/// call would do*, not to the proposal that asked, so the resend presents a different proposal id
/// and is still recognised. Every test here goes through `ToolAuthorityGate` rather than
/// `AuthorityBroker` directly, because the part that can be got wrong is the app's bookkeeping
/// around the broker, not the broker.
@Suite("Tool approval")
struct ToolApprovalTests {
    private static let tool = "calculator"

    private func gate(requiresApproval: Bool = true) -> ToolAuthorityGate {
        ToolAuthorityGate(
            capabilities: ToolAuthorityGate.readOnly(tools: [Self.tool]),
            requiresApproval: requiresApproval
        )
    }

    private func decide(
        _ gate: ToolAuthorityGate,
        arguments: String = #"{"expression":"2+2"}"#,
        provenance: Provenance = .modelAuthored
    ) async -> ToolAuthorityVerdict {
        await gate.decide(
            tool: Self.tool,
            arguments: arguments,
            conversationID: "conv-1",
            provenance: provenance
        )
    }

    @Test("the toggle turns an ordinary read-only capability into one that needs a signature")
    func toggleDemandsSignature() async {
        let gate = self.gate(requiresApproval: false)
        guard case .allowed = await decide(gate) else {
            Issue.record("expected .allowed while the toggle is off")
            return
        }

        await gate.setRequiresApproval(true)
        guard case .approvalRequired = await decide(gate) else {
            Issue.record("expected .approvalRequired once the toggle is on")
            return
        }
        #expect(await gate.isApprovalRequired)
    }

    @Test("the pending prompt carries the arguments and the resource, not just the tool name")
    func promptCarriesTheCall() async {
        let gate = self.gate()
        _ = await decide(gate)

        let prompt = await gate.pendingApproval()
        #expect(prompt?.tool == Self.tool)
        #expect(prompt?.resource == "tools/calculator")
        #expect(prompt?.arguments == #"{"expression":"2+2"}"#)
        #expect(prompt?.provenance == "model")
        #expect(prompt?.isUntrusted == false)
    }

    @Test("arguments shaped by retrieval are flagged, because that is the case worth refusing")
    func untrustedProvenanceIsFlagged() async {
        // `.untrusted` is denied outright by a `.modelAuthored` capability, so the approval branch
        // is only reachable when the capability admits it. That is the realistic shape of a tool
        // allowed to act on retrieved text at all.
        let permissive = Capability(
            tool: ToolName(Self.tool),
            actions: [.read],
            scope: .subtree(ResourcePath("tools/\(Self.tool)")),
            maxProvenance: .untrusted(source: "doc-1"),
            requiresApproval: true
        )
        let gate = ToolAuthorityGate(capabilities: [permissive])
        _ = await decide(gate, provenance: .untrusted(source: "doc-1"))

        let prompt = await gate.pendingApproval()
        #expect(prompt?.isUntrusted == true)
        #expect(prompt?.provenance == "untrusted(doc-1)")
    }

    @Test("signing lets the identical call through on the resend, under a fresh proposal id")
    func signatureSurvivesTheResend() async {
        let gate = self.gate()
        guard case .approvalRequired = await decide(gate) else {
            Issue.record("expected the first call to ask")
            return
        }
        #expect(await gate.approvePending(approver: "you"))

        guard case let .allowed(detail) = await decide(gate) else {
            Issue.record("expected the resend to be allowed")
            return
        }
        // The audit trail has to name who signed, or an approval is indistinguishable from a
        // capability that never needed one.
        #expect(detail.contains("approved by you"))
        let stats = await gate.statistics()
        #expect(stats.approvalsConsumed == 1)
    }

    @Test("a signature is spent once: the next identical call asks again rather than failing")
    func signatureIsSpentOnce() async {
        let gate = self.gate()
        _ = await decide(gate)
        #expect(await gate.approvePending(approver: "you"))
        guard case .allowed = await decide(gate) else {
            Issue.record("expected the approved call to run")
            return
        }

        // The broker throws `approvalAlreadyUsed` if a spent signature is presented again, and the
        // gate maps a throw to `.failed` — which would tell the user the system broke when all
        // they did was ask the same question twice. Taking the signature out of the dictionary as
        // it is used is what keeps this an ordinary second request.
        guard case .approvalRequired = await decide(gate) else {
            Issue.record("expected a second approval request, not a failure")
            return
        }
    }

    @Test("declining leaves the turn refused and signs nothing")
    func decliningSignsNothing() async {
        let gate = self.gate()
        _ = await decide(gate)
        await gate.declinePending()

        #expect(await gate.pendingApproval() == nil)
        guard case .approvalRequired = await decide(gate) else {
            Issue.record("a declined call must not be allowed through")
            return
        }
    }

    @Test("approving with nothing pending reports false rather than signing a blank cheque")
    func approvingNothingIsRefused() async {
        let gate = self.gate()
        #expect(await gate.approvePending(approver: "you") == false)
    }

    @Test("turning the requirement off and on again does not re-arm an old signature")
    func togglingClearsSignatures() async {
        let gate = self.gate()
        _ = await decide(gate)
        #expect(await gate.approvePending(approver: "you"))

        await gate.setRequiresApproval(false)
        await gate.setRequiresApproval(true)

        guard case .approvalRequired = await decide(gate) else {
            Issue.record("a signature given under the old policy must not survive the round trip")
            return
        }
    }

    @Test("a signature authorizes one call, not the tool: different arguments ask again")
    func signatureIsBoundToTheArguments() async {
        let gate = self.gate()
        _ = await decide(gate)
        #expect(await gate.approvePending(approver: "you"))

        // Same tool, same resource, different arguments — a different digest, so the signature
        // does not apply. This is the property that makes approving "calculator" safe.
        guard case .approvalRequired = await decide(gate, arguments: #"{"expression":"9*9"}"#) else {
            Issue.record("a different call must not ride on the previous signature")
            return
        }
    }

    // MARK: - The round trip's passthroughs

    /// `ToolRoundTrip` forwards four calls to the gate. They are trivial, which is exactly why they
    /// are worth a test: a passthrough wired to the wrong method compiles perfectly.
    @Test("the round trip forwards approval to the gate it actually asks for decisions")
    func roundTripForwardsApproval() async {
        let gate = self.gate(requiresApproval: false)
        let registry = ToolRegistryKit.ToolRegistry()
        await registry.register(DemoTools.calculator, handler: DemoTools.calculatorHandler())
        let roundTrip = ToolRoundTrip(registry: registry, gate: gate)

        await roundTrip.setApprovalRequired(true)
        let context = ToolCallContext(conversationID: "conv-1", provenance: .modelAuthored)
        let blocked = await roundTrip.resolve(
            id: "call-1",
            toolName: Self.tool,
            argumentsJSON: Data(#"{"expression":"2+2"}"#.utf8),
            in: context
        )
        #expect(blocked.refusal?.headline == "Approval needed")
        // Nothing may have run: an approval that dispatches first is decoration.
        let stats = await roundTrip.statistics()
        #expect(stats.totalCalls == 0)

        let prompt = await roundTrip.pendingApproval()
        #expect(prompt?.tool == Self.tool)
        #expect(await roundTrip.approvePending(approver: "you"))

        let allowed = await roundTrip.resolve(
            id: "call-2",
            toolName: Self.tool,
            argumentsJSON: Data(#"{"expression":"2+2"}"#.utf8),
            in: context
        )
        #expect(allowed.refusal == nil)
        #expect(allowed.observation?.contains("4") == true)
    }

    @Test("declining through the round trip clears the gate's pending request")
    func roundTripDeclines() async {
        let gate = self.gate()
        let registry = ToolRegistryKit.ToolRegistry()
        await registry.register(DemoTools.calculator, handler: DemoTools.calculatorHandler())
        let roundTrip = ToolRoundTrip(registry: registry, gate: gate)

        _ = await roundTrip.resolve(
            id: "call-1",
            toolName: Self.tool,
            argumentsJSON: Data(#"{"expression":"2+2"}"#.utf8),
            in: ToolCallContext(conversationID: "conv-1", provenance: .modelAuthored)
        )
        #expect(await roundTrip.pendingApproval() != nil)
        await roundTrip.declinePending()
        #expect(await roundTrip.pendingApproval() == nil)
    }
}
