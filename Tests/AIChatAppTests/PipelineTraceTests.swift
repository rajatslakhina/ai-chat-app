import Foundation
import Testing
@testable import AIChatApp

@Suite("Pipeline stages")
struct PipelineStageTests {
    /// The check that keeps the wiring honest as stages are added.
    @Test("every stage names a real package and has a title")
    func everyStageIsAttributed() {
        for stage in PipelineStage.allCases {
            #expect(!stage.package.isEmpty, "\(stage.rawValue) has no owning package")
            // Every package in the series is named *Kit except one: llm-eval-harness-kit ships
            // its library as `EvalHarness`. Naming it "EvalHarnessKit" here to satisfy a pattern
            // would put a module name in the Diagnostics screen that does not exist.
            #expect(
                stage.package.hasSuffix("Kit") || stage.package == "EvalHarness",
                "\(stage.rawValue) names \(stage.package)"
            )
            #expect(!stage.title.isEmpty, "\(stage.rawValue) has no title")
        }
    }

    /// The count that makes "all 44 packages are wired in" checkable rather than claimed.
    @Test("the stages cover all 44 ecosystem packages, each at least once")
    func coversEveryPackage() {
        let packages = Set(PipelineStage.allCases.map(\.package))
        let expected: Set<String> = [
            "ProviderGatewayKit", "StructuredOutputKit", "TokenMeterKit", "ResponseCacheKit",
            "ToolRegistryKit", "AgentLoopKit", "GuardrailKit", "TraceKit", "RetrievalKit",
            "PromptTemplateKit", "RetryPolicyKit", "ContextCompactionKit", "AgentMemoryKit",
            "SemanticRouterKit", "OutputRepairKit", "StreamAggregatorKit", "BatchInferenceKit",
            "RealtimeSessionKit", "IdempotencyKit", "SchemaMigrationKit", "ToolAuthorityKit",
            "GroundingKit", "QuotaGovernorKit", "CostEstimatorKit", "WorkloadProfilerKit",
            "SpotlightRAGKit", "EvalHarness", "ClaimConsistencyKit", "SourceConflictKit",
            "ClaimSegmenterKit", "CitationBindingKit", "ClaimDecontextualizerKit",
            "AnswerabilityKit", "MorphologyMatchKit", "EvidenceSensitivityKit",
            "SourceIndependenceKit", "TemporalValidityKit", "AbstentionPolicyKit",
            "SignalDependenceKit", "ConformalGateKit", "CensoredFeedbackKit",
            "ExplorationChannelKit", "LabelReturnKit", "DelaySignalKit"
        ]
        #expect(expected.count == 44)
        let missing = expected.subtracting(packages)
        let unexpected = packages.subtracting(expected)
        #expect(packages == expected, "missing: \(missing); unexpected: \(unexpected)")
    }

    @Test("stage identity is its raw value, so Diagnostics rows are stable")
    func identity() {
        #expect(PipelineStage.grounding.id == "grounding")
        #expect(Set(PipelineStage.allCases.map(\.id)).count == PipelineStage.allCases.count)
    }

    @Test("the two-stage packages appear at both ends of the turn")
    func pairedStages() {
        #expect(PipelineStage.guardrailInput.package == PipelineStage.guardrailOutput.package)
        #expect(PipelineStage.budgetReserve.package == PipelineStage.budgetSettle.package)
    }
}

@Suite("Stage outcomes")
struct StageOutcomeTests {
    private let sampleRefusal = Refusal(
        stage: .budgetReserve,
        headline: "Out of budget",
        explanation: "This conversation has used its monthly allowance.",
        recovery: .addCredit
    )

    @Test("a refusal is not a failure, and both report themselves honestly")
    func refusalIsNotFailure() {
        let refused = StageOutcome.refused(sampleRefusal)
        let failed = StageOutcome.failed(message: "socket closed")

        #expect(refused.isRefusal)
        #expect(!refused.isFailure)
        #expect(failed.isFailure)
        #expect(!failed.isRefusal, "a broken stage is not the system correctly saying no")
    }

    @Test("doing nothing on purpose is not the same as being skipped")
    func noOpVersusSkipped() {
        let noOp = StageOutcome.noOp(reason: "cache miss")
        let skipped = StageOutcome.skipped(reason: "retrieval disabled in Settings")

        #expect(!noOp.isRefusal && !noOp.isFailure)
        #expect(!skipped.isRefusal && !skipped.isFailure)
        #expect(noOp != skipped)
    }

    @Test("every outcome yields a non-empty line for Diagnostics")
    func summaries() {
        let outcomes: [StageOutcome] = [
            .ran(detail: "redacted 2 spans"),
            .noOp(reason: "nothing to compact"),
            .skipped(reason: "no tools declared"),
            .refused(sampleRefusal),
            .failed(message: "boom")
        ]
        for outcome in outcomes {
            #expect(!outcome.summary.isEmpty)
        }
        #expect(StageOutcome.refused(sampleRefusal).summary == "Out of budget")
    }
}

@Suite("Refusals reach the user")
struct RefusalTests {
    /// The rule this whole type exists to enforce.
    @Test("every recovery action offers a button title the user can act on")
    func everyRecoveryIsActionable() {
        let actions: [Refusal.RecoveryAction] = [
            .openSettings(field: "apiKey"),
            .retryLater(after: .seconds(30)),
            .retryLater(after: nil),
            .switchModel,
            .shortenConversation,
            .approveTool(name: "get_weather"),
            .addCredit
        ]
        for action in actions {
            let refusal = Refusal(
                stage: .providerRouting,
                headline: "h",
                explanation: "e",
                recovery: action
            )
            #expect(refusal.recoveryTitle?.isEmpty == false, "\(action) produced no title")
        }
    }

    @Test("a retry-after delay is shown as a concrete wait, not a vague one")
    func retryDelayIsConcrete() {
        let refusal = Refusal(
            stage: .providerRouting,
            headline: "Rate limited",
            explanation: "OpenRouter asked us to slow down.",
            recovery: .retryLater(after: .seconds(30))
        )
        #expect(refusal.recoveryTitle == "Try again in 30s")
    }

    @Test("a refusal with nothing to do about it says so rather than offering a dead button")
    func noRecovery() {
        let refusal = Refusal(
            stage: .grounding,
            headline: "Answer could not be verified",
            explanation: "No source supported the claim.",
            recovery: nil
        )
        #expect(refusal.recoveryTitle == nil)
    }
}

@Suite("Pipeline trace")
struct PipelineTraceTests {
    private func makeTrace() -> PipelineTrace {
        var trace = PipelineTrace()
        trace.record(.promptTemplate, .ran(detail: "applied 'default' v3"), durationMs: 2)
        trace.record(.guardrailInput, .ran(detail: "redacted 1 email"), durationMs: 4)
        trace.record(.cacheLookup, .noOp(reason: "cache miss"), durationMs: 1)
        return trace
    }

    @Test("records keep insertion order and accumulate duration")
    func ordering() {
        let trace = makeTrace()
        #expect(trace.records.map(\.stage) == [.promptTemplate, .guardrailInput, .cacheLookup])
        #expect(trace.totalDurationMs == 7)
    }

    @Test("the first refusal is the one that stopped the turn")
    func firstRefusalWins() {
        var trace = makeTrace()
        trace.record(
            .budgetReserve,
            .refused(
                Refusal(
                    stage: .budgetReserve,
                    headline: "Out of budget",
                    explanation: "e",
                    recovery: .addCredit
                )
            )
        )
        trace.record(
            .providerRouting,
            .refused(
                Refusal(stage: .providerRouting, headline: "Later", explanation: "e", recovery: nil)
            )
        )
        #expect(trace.refusal?.headline == "Out of budget")
        #expect(trace.refusal?.stage == .budgetReserve)
    }

    @Test("a clean run has no refusal and no failures")
    func cleanRun() {
        let trace = makeTrace()
        #expect(trace.refusal == nil)
        #expect(trace.failures.isEmpty)
    }

    @Test("failures are collected separately from refusals")
    func failuresCollected() {
        var trace = makeTrace()
        trace.record(.metering, .failed(message: "registry unavailable"))
        #expect(trace.failures.count == 1)
        #expect(trace.failures.first?.stage == .metering)
        #expect(trace.refusal == nil, "a failure is not a refusal")
    }

    /// Makes a package that silently did nothing visible, rather than invisible.
    @Test("stages that never ran are reported as unreached")
    func unreachedStages() {
        let trace = makeTrace()
        let unreached = trace.unreached
        #expect(!unreached.contains(.promptTemplate))
        #expect(unreached.contains(.metering))
        #expect(unreached.count == PipelineStage.allCases.count - 3)
    }

    @Test("a stage's outcome can be looked up directly for its Diagnostics row")
    func lookup() {
        let trace = makeTrace()
        #expect(trace.outcome(for: .cacheLookup) == .noOp(reason: "cache miss"))
        #expect(trace.outcome(for: .grounding) == nil)
    }

    @Test("an empty trace reports everything as unreached rather than as complete")
    func emptyTrace() {
        let trace = PipelineTrace()
        #expect(trace.records.isEmpty)
        #expect(trace.unreached.count == PipelineStage.allCases.count)
        #expect(trace.totalDurationMs == 0)
        #expect(trace.refusal == nil)
    }

    @Test("a trace can be constructed from existing records for previews and snapshots")
    func constructedFromRecords() {
        let trace = PipelineTrace(records: [
            StageRecord(stage: .metering, outcome: .ran(detail: "18 in / 7 out"), durationMs: 1)
        ])
        #expect(trace.records.count == 1)
        #expect(trace.outcome(for: .metering)?.summary == "18 in / 7 out")
    }
}
