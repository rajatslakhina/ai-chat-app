import FleetRollout
import Foundation
import Testing
@testable import AIChatApp

/// The `fleetRollout` stage: a fleet-wide kill switch for semantic routing, independent of
/// whatever `PipelineSettings.routingEnabled` says on this device.
@Suite("Fleet rollout stage")
struct FleetRolloutStageTests {
    private func assignment(
        variant: String, value: Bool, reason: EvaluationReason
    ) -> Assignment {
        Assignment(
            flagKey: FleetRolloutGate.flagKey, variantKey: variant, value: .bool(value),
            reason: reason, documentVersion: 1, bucket: nil, matchedRuleID: nil)
    }

    @Test("the session's own rollout on resolves to a no-op, not silence")
    func defaultVariantOnIsNoOp() {
        let (allowed, outcome) = PreModelPipeline.fleetRolloutDecision(
            assignment(variant: "on", value: true, reason: .defaultVariant))
        #expect(allowed)
        guard case .noOp(let reason) = outcome else {
            Issue.record("expected a no-op, got \(outcome)")
            return
        }
        #expect(reason.contains("in the routing rollout"))
    }

    @Test("a session outside the rollout is skipped, not treated as a failure")
    func offVariantIsSkipped() {
        let (allowed, outcome) = PreModelPipeline.fleetRolloutDecision(
            assignment(variant: "off", value: false, reason: .ruleMatch))
        #expect(!allowed)
        guard case .skipped(let reason) = outcome else {
            Issue.record("expected a skip, got \(outcome)")
            return
        }
        #expect(reason.contains("outside the routing rollout"))
    }

    @Test("a killed flag routes to the compiled-in fallback and is reported skipped")
    func killedFlagIsSkipped() {
        let (allowed, outcome) = PreModelPipeline.fleetRolloutDecision(
            assignment(variant: "fallback", value: false, reason: .killed))
        #expect(!allowed, "a kill switch that fell back to on would not be one")
        guard case .skipped(let reason) = outcome else {
            Issue.record("expected a skip, got \(outcome)")
            return
        }
        #expect(reason.contains("killed fleet-wide"))
    }

    @Test("a non-boolean flag value falls back to allowed rather than crashing")
    func nonBooleanValueFallsBackToAllowed() {
        let nonBoolean = Assignment(
            flagKey: FleetRolloutGate.flagKey, variantKey: "on", value: .string("unexpected"),
            reason: .defaultVariant, documentVersion: 1, bucket: nil, matchedRuleID: nil)
        let (allowed, outcome) = PreModelPipeline.fleetRolloutDecision(nonBoolean)
        #expect(allowed, "a flag value that is not a bool should fail open, not fail closed")
        guard case .noOp = outcome else {
            Issue.record("expected a no-op, got \(outcome)")
            return
        }
    }

    @Test("an unresolvable flag is reported failed rather than silently routing")
    func unresolvableFlagIsFailed() {
        for reason: EvaluationReason in [.unknownFlag, .noDocument, .refusedMalformedRule] {
            let (_, outcome) = PreModelPipeline.fleetRolloutDecision(
                assignment(variant: "fallback", value: false, reason: reason))
            guard case .failed(let message) = outcome else {
                Issue.record("expected a failure for \(reason), got \(outcome)")
                continue
            }
            #expect(message.contains("\(reason)"))
        }
    }

    @Test("the real gate, run against the app's bundled document, is a no-op by default")
    func realGateDefaultsToNoOp() {
        var trace = PipelineTrace()
        let allowed = PreModelPipeline.fleetRolloutGate(trace: &trace)
        #expect(allowed)
        guard let outcome = trace.records.first(where: { $0.stage == .fleetRollout })?.outcome else {
            Issue.record("fleetRollout stage was not recorded")
            return
        }
        guard case .noOp = outcome else {
            Issue.record("expected a no-op, got \(outcome)")
            return
        }
    }

    @Test("the gate is deterministic for the same persisted install identifier")
    func deterministicAcrossCalls() {
        var first = PipelineTrace()
        var second = PipelineTrace()
        let allowedFirst = PreModelPipeline.fleetRolloutGate(trace: &first)
        let allowedSecond = PreModelPipeline.fleetRolloutGate(trace: &second)
        #expect(allowedFirst == allowedSecond)
    }

    @Test("a fresh suite generates and persists an identifier; a second read returns the same one")
    func sessionDeviceGeneratesThenPersists() throws {
        let suiteName = "fleet-rollout-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(defaults.string(forKey: FleetRolloutGate.identifierKey) == nil)
        let first = FleetRolloutGate.sessionDevice(defaults: defaults)
        let savedAfterFirst = defaults.string(forKey: FleetRolloutGate.identifierKey)
        #expect(savedAfterFirst == first.stableIdentifier)

        let second = FleetRolloutGate.sessionDevice(defaults: defaults)
        #expect(second.stableIdentifier == first.stableIdentifier)
    }

    /// The stage table has to name every package in the series, and this one is the reminder.
    @Test("the new stage names its package and its title")
    func catalogued() {
        #expect(PipelineStage.fleetRollout.package == "FleetRolloutKit")
        #expect(PipelineStage.fleetRollout.title == "Fleet rollout gate")
    }
}
