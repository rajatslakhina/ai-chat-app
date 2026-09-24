import Foundation
import ToolIntegrityKit
import ToolRegistryKit

/// Verifies this app's tool catalog against the fingerprint it was approved under, before every
/// turn — the free, per-turn half of the MCP "rug pull" defense (OWASP MCP03:2025,
/// CVE-2025-54136) `ToolIntegrityKit` exists for. `ToolAuthorityKit`'s `toolAuthority` stage
/// answers "is this call permitted" for a call the model already proposed; this stage answers a
/// question that has to be settled earlier — is the tool catalog the model is about to see even
/// the one anybody reviewed.
///
/// Honest scope: `DemoTools.calculator` and `DemoTools.currentTime` are Swift constants, not a
/// live MCP catalog, so nothing in this app can actually rewrite them between turns today — this
/// stage cannot catch a real rug pull here, and this comment says so rather than dressing up a
/// gate that never fires as one that does real work. What it genuinely does catch: the gate's
/// ledger is seeded from whichever definition it saw *first*, at the first turn of the process,
/// and every later turn's `verify(_:)` call is a real, non-trivial comparison against that
/// baseline — poisoned-content scanning runs on every single call, first turn included. The
/// moment this app's tool source becomes dynamic (a real MCP server), this exact wiring is what
/// would catch a provider rewriting a tool after approval; nothing here would need to change,
/// only what feeds `ToolIntegrityBridge.integrityDefinition(for:)`.
enum ToolIntegrityStage {
    /// One process-lifetime ledger. A fresh gate per turn would defeat the entire point — a rug
    /// pull is only visible as a *change* from what an earlier turn saw.
    static let gate = ToolIntegrityGate()

    /// Pure: maps a verdict to what the stage records and whether the turn may proceed. Split out
    /// exactly as `PreModelPipeline.fleetRolloutDecision(_:)` is, so `.driftDetected`,
    /// `.shadowed` and `.suspiciousContent` are directly testable even though this app's static
    /// tool catalog can never actually produce them through the live pipeline.
    static func decision(
        for verdict: ToolIntegrityVerdict,
        toolName: String
    ) -> (allowed: Bool, outcome: StageOutcome) {
        switch verdict {
        case let .newlyApproved(fingerprint):
            let digest = fingerprint.descriptionDigest.prefix(8)
            return (true, .ran(detail: "\(toolName): baseline established (\(digest))"))
        case let .trusted(fingerprint):
            let digest = fingerprint.descriptionDigest.prefix(8)
            return (true, .ran(detail: "\(toolName): matches baseline (\(digest))"))
        case let .driftDetected(_, _, changedFields):
            let fields = changedFields.map(\.rawValue).joined(separator: ", ")
            return (false, .refused(Refusal(
                stage: .toolIntegrity,
                headline: "A tool's definition changed unexpectedly",
                explanation: "\(toolName) no longer matches what was approved (changed: \(fields)). " +
                    "This app will not send an unreviewed tool definition to a model.",
                recovery: nil
            )))
        case let .shadowed(existingApprovedName, similarity):
            let percent = Int((similarity * 100).rounded())
            return (false, .refused(Refusal(
                stage: .toolIntegrity,
                headline: "A tool name looked like a lookalike",
                explanation: "\(toolName) is \(percent)% similar to the already-approved " +
                    "\"\(existingApprovedName)\" and was not auto-approved.",
                recovery: nil
            )))
        case let .suspiciousContent(patterns):
            return (false, .refused(Refusal(
                stage: .toolIntegrity,
                headline: "A tool definition looked tampered with",
                explanation: "\(toolName)'s description or parameters matched a known " +
                    "tool-poisoning pattern (\(patterns.count) signal(s)) and was refused.",
                recovery: nil
            )))
        }
    }
}

extension PreModelPipeline {
    /// The one-line call site `prepare()` uses, matching `fleetRolloutGate(trace:)`'s shape —
    /// everything else about this stage lives in this file, not in `PreModelPipeline.swift`.
    static func toolIntegrityRefusal(trace: inout PipelineTrace) async -> Refusal? {
        await verifyToolCatalog([DemoTools.calculator, DemoTools.currentTime], trace: &trace)
    }

    /// Verifies every registered tool definition before the turn proceeds. Runs before
    /// `chooseModel`, for the same reason the fleet gate does: a later stage should see the
    /// catalog already checked, not check part of it itself.
    ///
    /// `gate` defaults to the shared, process-lifetime ledger; tests inject a fresh one so one
    /// test's approvals cannot leak into the next test's "first sight" of the same tool name.
    static func verifyToolCatalog(
        _ definitions: [ToolRegistryKit.ToolDefinition],
        trace: inout PipelineTrace,
        gate: ToolIntegrityGate = ToolIntegrityStage.gate
    ) async -> Refusal? {
        for definition in definitions {
            let integrityDefinition = ToolIntegrityBridge.integrityDefinition(for: definition)
            let verdict = await gate.verify(integrityDefinition)
            let (allowed, outcome) = ToolIntegrityStage.decision(for: verdict, toolName: definition.name)
            trace.record(.toolIntegrity, outcome)
            if !allowed, case let .refused(refusal) = outcome {
                return refusal
            }
        }
        if definitions.isEmpty {
            trace.record(.toolIntegrity, .noOp(reason: "no tools registered"))
        }
        return nil
    }
}
