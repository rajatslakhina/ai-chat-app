import Foundation
import Testing
import ToolAuthorityKit
import ToolRegistryKit
@testable import AIChatApp

/// The `trajectoryConsistency` stage: canonical arguments before authority and dispatch, and the
/// replay check behind "approve, then resend".
///
/// The first test pins the bug this stage fixes. Before it, the gate hashed the argument text the
/// model wrote, so a resend that spelled the signed call differently missed its own signature and
/// the user was asked to approve the same calculation twice.
@Suite("Tool call replay")
struct ToolCallReplayTests {
    private static let tool = "calculator"

    private func roundTrip(requiresApproval: Bool = true) async -> (ToolRoundTrip, ToolAuthorityGate) {
        let gate = ToolAuthorityGate(
            capabilities: ToolAuthorityGate.readOnly(tools: [Self.tool]),
            requiresApproval: requiresApproval
        )
        let registry = ToolRegistryKit.ToolRegistry()
        await registry.register(DemoTools.calculator, handler: DemoTools.calculatorHandler())
        return (ToolRoundTrip(registry: registry, gate: gate), gate)
    }

    private func resolve(
        _ roundTrip: ToolRoundTrip,
        _ arguments: String,
        id: String,
        conversation: String = "conv-1"
    ) async -> ToolCallResolution {
        await roundTrip.resolve(
            id: id,
            toolName: Self.tool,
            argumentsJSON: Data(arguments.utf8),
            in: ToolCallContext(conversationID: conversation, provenance: .modelAuthored)
        )
    }

    private func outcome(_ resolution: ToolCallResolution) -> StageOutcome? {
        resolution.records.first { $0.stage == .trajectoryConsistency }?.outcome
    }

    private func request(_ arguments: String, tool: String = "calculator", conversation: String = "conv-1") -> ApprovalRequest {
        ApprovalRequest(
            proposal: ToolProposal(
                id: "p", principal: conversation, tool: ToolName(tool), action: .read,
                resource: ResourcePath("tools/\(tool)"), arguments: arguments, provenance: .modelAuthored
            ),
            grantID: "g"
        )
    }

    @Test("the stage names its package and its Diagnostics title")
    func catalog() {
        #expect(PipelineStage.trajectoryConsistency.package == "TrajectoryConsistencyKit")
        #expect(PipelineStage.trajectoryConsistency.title == "Argument canonicalization")
    }

    @Test("a resend that respells the signed call runs on the signature")
    func respelledResendCarriesTheSignature() async {
        let (roundTrip, gate) = await roundTrip()
        let first = await resolve(roundTrip, #"{"expression": "2+2"}"#, id: "c1")
        #expect(first.refusal?.headline == "Approval needed")
        #expect(outcome(first) == .ran(detail: "arguments respelled canonically (21 \u{2192} 20 bytes)"))
        #expect(first.records.first?.stage == .trajectoryConsistency)
        #expect(await roundTrip.approvePending(approver: "you"))
        #expect(await gate.signedCallAwaitingReplay(conversationID: "conv-1")?.arguments == #"{"expression":"2+2"}"#)

        let resend = await resolve(roundTrip, #"{ "expression" : "2+2" }"#, id: "c2")
        #expect(resend.refusal == nil)
        #expect(resend.observation?.contains("4") == true)
        #expect(outcome(resend) == .ran(
            detail: "arguments respelled canonically (24 \u{2192} 20 bytes); this is the call you signed, so the signature applies"
        ))
        #expect(await gate.signedCallAwaitingReplay(conversationID: "conv-1") == nil)
        let stats = await roundTrip.statistics()
        #expect(stats.totalCalls == 1)
    }

    @Test("a resend that changes the signed call asks again and says what changed")
    func changedResendIsNamed() async {
        let (roundTrip, _) = await roundTrip()
        _ = await resolve(roundTrip, #"{"expression":"2+2"}"#, id: "c1")
        #expect(await roundTrip.approvePending(approver: "you"))

        let resend = await resolve(roundTrip, #"{"expression":"9*9"}"#, id: "c2")
        let change = #"the same tool with different arguments: expression: "2+2" \#u{2192} "9*9""#
        #expect(resend.refusal?.headline == "Approval needed")
        #expect(resend.refusal?.explanation.hasSuffix("It differs from the call you approved: \(change).") == true)
        #expect(outcome(resend) == .ran(detail: "arguments already canonical; this is not the call you signed: \(change)"))
        let stats = await roundTrip.statistics()
        #expect(stats.totalCalls == 0)
    }

    @Test("arguments with two readings go through as written, and the stage says why")
    func ambiguousArgumentsAreSkipped() async {
        let (roundTrip, _) = await roundTrip(requiresApproval: false)
        let resolution = await resolve(roundTrip, #"{"expression":"2+2","expression":"9*9"}"#, id: "c1")
        #expect(outcome(resolution) == .skipped(
            reason: #"the arguments repeat the key "expression", so their meaning is ambiguous; "#
                + "authorized and dispatched without canonicalization"
        ))
        let stats = await roundTrip.statistics()
        #expect(stats.totalCalls == 1)
    }

    @Test("an empty arguments field becomes the empty object OpenRouter means by it")
    func emptyArguments() {
        let canonical = ToolCallReplay.canonical(Data())
        #expect(canonical == ToolCallReplay.Canonical(arguments: Data("{}".utf8), text: "{}", problem: nil))
        let record = ToolCallReplay.record(original: Data(), canonical: canonical, tool: "now", signed: nil)
        #expect(record.outcome == .ran(detail: "arguments respelled canonically (0 \u{2192} 2 bytes)"))
    }

    @Test("undecodable bytes are reported, not described as a respelling")
    func invalidUTF8IsSkipped() {
        let canonical = ToolCallReplay.canonical(Data([0xC3, 0x28]))
        #expect(canonical == ToolCallReplay.Canonical(arguments: Data("{}".utf8), text: "{}", problem: .notUTF8))
    }

    @Test("a signature from another conversation is neither offered nor described")
    func otherConversationsSignatureIsIgnored() async {
        let (roundTrip, _) = await roundTrip()
        _ = await resolve(roundTrip, #"{"expression":"2+2"}"#, id: "c1", conversation: "conv-1")
        #expect(await roundTrip.approvePending(approver: "you"))

        let other = await resolve(roundTrip, #"{"expression":"9*9"}"#, id: "c2", conversation: "conv-2")
        #expect(other.refusal?.headline == "Approval needed")
        #expect(other.refusal?.explanation.contains("differs") == false)
        #expect(outcome(other) == .ran(detail: "arguments already canonical"))
    }

    @Test("turning approval off and on forgets the call waiting for its resend")
    func toggleForgetsTheWaitingCall() async {
        let (roundTrip, gate) = await roundTrip()
        _ = await resolve(roundTrip, #"{"expression":"2+2"}"#, id: "c1")
        #expect(await roundTrip.approvePending(approver: "you"))
        await gate.setRequiresApproval(false)
        #expect(await gate.signedCallAwaitingReplay(conversationID: "conv-1") == nil)
    }

    @Test("difference is nil for the signed call itself and names a changed tool or an unreadable one")
    func differenceCases() {
        let signed = request(#"{"expression":"2+2"}"#)
        #expect(ToolCallReplay.difference(signed: signed, proposed: signed) == nil)
        #expect(
            ToolCallReplay.difference(signed: signed, proposed: request("{}", tool: "now"))
                == "It differs from the call you approved: a different tool: now instead of calculator."
        )
        let unreadable = request(#"{"expression":"2+2","expression":"3"}"#)
        #expect(
            ToolCallReplay.difference(signed: unreadable, proposed: signed)
                == "It differs from the call you approved: a call that cannot be compared: "
                + #"the arguments repeat the key "expression", so their meaning is ambiguous."#
        )
    }

    @Test("a waiting signature on an unreadable call is reported as not this call")
    func recordAgainstUnreadableSignature() {
        let signed = request(#"{"expression":"2+2","expression":"3"}"#)
        let canonical = ToolCallReplay.canonical(Data(#"{"expression":"2+2"}"#.utf8))
        let record = ToolCallReplay.record(
            original: Data(#"{"expression":"2+2"}"#.utf8), canonical: canonical, tool: "calculator", signed: signed
        )
        #expect(record.outcome == .ran(
            detail: "arguments already canonical; this is not the call you signed: a call that cannot be compared: "
                + #"the arguments repeat the key "expression", so their meaning is ambiguous"#
        ))
    }
}
