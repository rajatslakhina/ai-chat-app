import AgentMemoryKit
import ContextCompactionKit
import EvidenceSensitivityKit
import GuardrailKit
import PromptTemplateKit
import ResponseCacheKit
import RetrievalKit
import SemanticRouterKit
import SourceIndependenceKit
import Testing
@testable import AIChatApp

/// The stage that asks how many independent sources are behind the passages the gate admitted.
@Suite("Source independence stage")
struct SourceIndependenceStageTests {
    private func pipeline() async -> PreModelPipeline {
        let prompts = PromptRegistry()
        _ = try? await prompts.register(name: "chat.system", template: "You are terse.")
        return PreModelPipeline(
            prompts: prompts,
            guardrail: GuardrailPipeline(policy: GuardrailPolicy()),
            router: SemanticRouter(),
            cache: ResponseCache(capacity: 4),
            memory: MemoryStore(),
            retriever: Retriever(embedder: HashingEmbeddingProvider()),
            compactor: ContextCompactor(strategies: [SlidingWindowCompactionStrategy()])
        )
    }

    private func source(_ id: String, title: String, snippet: String) -> RetrievedSource {
        RetrievedSource(id: id, title: title, snippet: snippet, relevancePercent: 80)
    }

    /// Long enough to clear the shingle floor, so the comparison is actually attempted.
    private let sharedText = """
    A failed deployment is rolled back automatically within two minutes of the health check \
    reporting a failure, and the engineer on call is paged only if that revert does not finish.
    """
    private let otherText = """
    Quarterly capacity planning is reviewed by the platform group every March, and the resulting \
    forecast is published to the internal wiki for the following two quarters.
    """

    // MARK: - When there is nothing to establish

    @Test("one passage is skipped, because independence is a question about several")
    func skipsBelowTwoPassages() async {
        let pipeline = await pipeline()
        var trace = PipelineTrace()
        let outcome = pipeline.establishSourceIndependence(
            of: [source("s1", title: "Runbook", snippet: sharedText)],
            trace: &trace
        )
        #expect(outcome == .notApplicable)
        #expect(trace.records.contains { $0.stage == .sourceIndependence && !$0.outcome.isRefusal })

        var emptyTrace = PipelineTrace()
        let emptyOutcome = pipeline.establishSourceIndependence(of: [], trace: &emptyTrace)
        #expect(emptyOutcome == .notApplicable)
    }

    @Test("when the titles already said it, the stage is a no-op rather than a finding")
    func noOpWhenTitlesSuffice() async {
        let pipeline = await pipeline()
        var trace = PipelineTrace()
        let outcome = pipeline.establishSourceIndependence(
            of: [
                source("s1", title: "Runbook", snippet: sharedText),
                source("s2", title: "Runbook", snippet: otherText)
            ],
            trace: &trace
        )
        guard case let .established(report) = outcome else {
            Issue.record("expected an established report, got \(outcome)")
            return
        }
        #expect(report.establishedSourceCount == 1)
        #expect(PreModelPipeline.redundancyMergedSources(in: report).isEmpty)
    }

    @Test("text matching merges what the titles missed, and says which families")
    func recordsRedundancyMerges() async {
        let pipeline = await pipeline()
        var trace = PipelineTrace()
        let outcome = pipeline.establishSourceIndependence(
            of: [
                source("s1", title: "Deployment runbook", snippet: sharedText),
                source("s2", title: "Rollback notes", snippet: sharedText + " Reviewed in March."),
                source("s3", title: "Capacity planning", snippet: otherText)
            ],
            trace: &trace
        )
        guard case let .established(report) = outcome else {
            Issue.record("expected an established report, got \(outcome)")
            return
        }
        #expect(report.establishedSourceCount == 2)
        #expect(PreModelPipeline.redundancyMergedSources(in: report).count == 1)
        let entry = trace.records.last { $0.stage == .sourceIndependence }
        #expect(entry?.outcome.isRefusal == false)
    }

    // MARK: - The one refusal

    @Test("everything collapsing to one source under different titles is refused, with a way out")
    func refusesCollapsedCorroboration() async {
        let pipeline = await pipeline()
        var trace = PipelineTrace()
        let outcome = pipeline.establishSourceIndependence(
            of: [
                source("s1", title: "Deployment runbook", snippet: sharedText),
                source("s2", title: "Rollback notes", snippet: sharedText + " Reviewed in March.")
            ],
            trace: &trace
        )
        guard case let .refused(refusal) = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        #expect(refusal.stage == .sourceIndependence)
        #expect(!refusal.headline.isEmpty)
        #expect(refusal.explanation.contains("same writing"))
        #expect(refusal.recovery != nil)
        #expect(trace.records.contains { $0.stage == .sourceIndependence && $0.outcome.isRefusal })
    }

    @Test("the refusal needs a single source, no gaps, and titles that actually differ")
    func refusalPreconditions() {
        let merged = [IndependentSource(id: "a", passageIDs: ["s1", "s2"], mergeReasons: [])]

        // Two sources standing: nothing is being misrepresented.
        let twoSources = IndependenceReport(
            sources: merged + [IndependentSource(id: "b", passageIDs: ["s3"], mergeReasons: [])],
            unattributed: [],
            redundancyChecks: []
        )
        #expect(PreModelPipeline.refusalForCollapsedCorroboration(
            twoSources,
            sources: [source("s1", title: "A", snippet: "x"), source("s3", title: "B", snippet: "y")],
            merged: merged
        ) == nil)

        // One source but one shared title: the user can already see they are the same document.
        let oneSource = IndependenceReport(sources: merged, unattributed: [], redundancyChecks: [])
        #expect(PreModelPipeline.refusalForCollapsedCorroboration(
            oneSource,
            sources: [source("s1", title: "A", snippet: "x"), source("s2", title: "A", snippet: "y")],
            merged: merged
        ) == nil)

        // Provenance incomplete: the count is a floor, not a claim that everything collapsed.
        let gappy = IndependenceReport(
            sources: merged,
            unattributed: [.noIdentifier(passageID: "s9")],
            redundancyChecks: []
        )
        #expect(PreModelPipeline.refusalForCollapsedCorroboration(
            gappy,
            sources: [source("s1", title: "A", snippet: "x"), source("s2", title: "B", snippet: "y")],
            merged: merged
        ) == nil)
    }

    @Test("a source with no title at all is a provenance gap, not an invented document")
    func untitledSourceBecomesAGap() async {
        let pipeline = await pipeline()
        var trace = PipelineTrace()
        let outcome = pipeline.establishSourceIndependence(
            of: [
                source("s1", title: "Deployment runbook", snippet: sharedText),
                source("s2", title: "", snippet: otherText)
            ],
            trace: &trace
        )
        guard case let .established(report) = outcome else {
            Issue.record("expected an established report, got \(outcome)")
            return
        }
        #expect(report.unattributed.map(\.passageID) == ["s2"])
        #expect(report.corroboratedSourceCount == nil)
        #expect(report.establishedSourceCount == 1)
    }

    // MARK: - What the stage hands downstream

    @Test("the derived key replaces the title, and the title remains the fallback")
    func derivedKeysReachTheStabilityPass() {
        let sources = [
            source("s1", title: "Deployment runbook", snippet: sharedText),
            source("s2", title: "Rollback notes", snippet: sharedText + " Reviewed in March."),
            source("s3", title: "Capacity planning", snippet: otherText)
        ]
        let report = SourceIndependenceAnalyzer().analyse(sources.map(PreModelPipeline.passage))
        let derived = PreModelPipeline.references(for: sources, independence: report)
        #expect(Set(derived.map(\.documentID)).count == 2)
        #expect(derived[0].documentID == derived[1].documentID)

        let fallback = PreModelPipeline.references(for: sources)
        #expect(fallback.map(\.documentID) == sources.map(\.title))
    }

    @Test("a passage carries the title as its document id and no invented locator")
    func passageMapping() {
        let mapped = PreModelPipeline.passage(for: source("s1", title: "Runbook", snippet: "text"))
        #expect(mapped.id == "s1")
        #expect(mapped.documentID == "Runbook")
        #expect(mapped.locator == nil)
        #expect(mapped.derivedFrom.isEmpty)
    }

    @Test("the flattened resolver reports all three outcomes the caller can get")
    func resolverArms() async {
        let pipeline = await pipeline()

        var oneTrace = PipelineTrace()
        let single = pipeline.resolveIndependence(
            of: [source("s1", title: "Runbook", snippet: sharedText)],
            trace: &oneTrace
        )
        #expect(single.report == nil)
        #expect(single.refusal == nil)

        var okTrace = PipelineTrace()
        let established = pipeline.resolveIndependence(
            of: [
                source("s1", title: "Deployment runbook", snippet: sharedText),
                source("s2", title: "Capacity planning", snippet: otherText)
            ],
            trace: &okTrace
        )
        #expect(established.report?.establishedSourceCount == 2)
        #expect(established.refusal == nil)

        var refusedTrace = PipelineTrace()
        let refused = pipeline.resolveIndependence(
            of: [
                source("s1", title: "Deployment runbook", snippet: sharedText),
                source("s2", title: "Rollback notes", snippet: sharedText + " Reviewed in March.")
            ],
            trace: &refusedTrace
        )
        #expect(refused.report == nil)
        #expect(refused.refusal?.stage == .sourceIndependence)
    }
}
