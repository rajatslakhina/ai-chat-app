import AgentLoopKit
import Foundation
import ProviderGatewayKit
import ToolRegistryKit

/// The effect executor's stateless helpers: argument re-encoding and the stage records for paths
/// where the tool round trip did not run. Split out of `ProviderEffectExecutor.swift` to keep that
/// file under SwiftLint's length limit when the in-doubt check was added.
extension ProviderEffectExecutor {
    /// Re-encodes the gateway's parsed arguments as the raw JSON bytes `ToolRegistryKit` wants.
    ///
    /// `ToolRegistryKit.ToolCallRequest` takes `argumentsJSON: Data`; ProviderGatewayKit's
    /// same-named type takes a parsed dictionary. The two are different types with the same name
    /// from two linked packages, which is why every mention of either is qualified.
    static func argumentsJSON(_ arguments: [String: LLMToolArgumentValue]) -> Data {
        let json = OpenRouterJSON.object(arguments.mapValues(OpenRouterJSON.init))
        return (try? JSONEncoder().encode(json)) ?? Data("{}".utf8)
    }

    static func unwiredRecords(for toolName: String) -> [StageRecord] {
        let reason = "\(toolName) was requested but no tool registry is configured"
        return [
            StageRecord(stage: .toolAuthority, outcome: .skipped(reason: reason), durationMs: 0),
            StageRecord(stage: .toolDispatch, outcome: .skipped(reason: reason), durationMs: 0)
        ]
    }

    static func toolNames(in transcript: AgentTranscript) -> [String] {
        transcript.steps.compactMap { step in
            guard case let .toolCall(request)? = step.decision else { return nil }
            return request.toolName
        }
    }

    /// Records the three tool stages for a turn that never reached the network, so a replayed send
    /// reads as "not repeated" rather than as three silently unwired packages.
    static func replayedRecords() -> [StageRecord] {
        let reason = "replayed an earlier result; the tool round trip was not repeated"
        return [PipelineStage.toolAuthority, .toolDispatch, .agentLoop].map {
            StageRecord(stage: $0, outcome: .skipped(reason: reason), durationMs: 0)
        } + [
            StageRecord(
                stage: .loopGuard,
                outcome: .skipped(reason: ToolLoopWatch.replayReason),
                durationMs: 0
            ),
            StageRecord(
                stage: .progressGate,
                outcome: .skipped(reason: ToolProgressCheck.replayReason),
                durationMs: 0
            )
        ] + StructuralToolSkips.records
    }

    /// Records the two dispatch-side stages for a turn where no tool call was made.
    ///
    /// `.noOp` when tools were offered and the model chose not to use one — the common path for
    /// ordinary chat. `.skipped` when there was nothing to offer, which is a different fact.
    static func untouchedRecords(toolsAvailable: Bool) -> [StageRecord] {
        let outcome: StageOutcome = toolsAvailable
            ? .noOp(reason: "model requested no tools")
            : .skipped(reason: "no tools registered for this conversation")
        return [PipelineStage.toolAuthority, PipelineStage.toolDispatch].map {
            StageRecord(stage: $0, outcome: outcome, durationMs: 0)
        } + StructuralToolSkips.records
    }
}
