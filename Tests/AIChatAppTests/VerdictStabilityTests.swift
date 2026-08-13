import AgentMemoryKit
import ContextCompactionKit
import EvidenceSensitivityKit
import GuardrailKit
import ResponseCacheKit
import PromptTemplateKit
import RetrievalKit
import SemanticRouterKit
import Testing
@testable import AIChatApp

/// The stage that asks whether the answerability gate's ruling depended on the evidence, or on
/// which passages retrieval happened to return this time.
@Suite("Verdict stability stage")
struct VerdictStabilityTests {
    private func pipeline() async -> PreModelPipeline {
        let prompts = PromptRegistry()
        _ = try? await prompts.register(name: "chat.system", template: "You are terse.")
        let retriever = Retriever(embedder: HashingEmbeddingProvider())
        return PreModelPipeline(
            prompts: prompts,
            guardrail: GuardrailPipeline(policy: GuardrailPolicy()),
            router: SemanticRouter(),
            cache: ResponseCache(capacity: 4),
            memory: MemoryStore(),
            retriever: retriever,
            compactor: ContextCompactor(strategies: [SlidingWindowCompactionStrategy()])
        )
    }

    private func report(
        _ verdict: StabilityVerdict,
        label: String = "answerable",
        probeCount: Int = 6
    ) -> SensitivityReport {
        SensitivityReport(
            baseline: VerdictReading(label: label, affirming: 0.9, denying: 0),
            verdict: verdict,
            itemPivots: [],
            documentPivots: nil,
            supportMargin: 0.5,
            probeCount: probeCount
        )
    }

    private func source(_ id: String, title: String, snippet: String = "text") -> RetrievedSource {
        RetrievedSource(id: id, title: title, snippet: snippet, relevancePercent: 80)
    }

    // MARK: - The document-identity proxy

    /// The app has no document identifier, so `title` stands in for one. Two chunks of one page
    /// must therefore collapse to one document — that collapse is the entire point of the stage.
    @Test("passages sharing a title are treated as one document")
    func referencesUseTitleAsDocument() {
        let refs = PreModelPipeline.references(for: [
            source("s1", title: "Runbook"),
            source("s2", title: "Runbook"),
            source("s3", title: "Deadlines")
        ])
        #expect(refs.map(\.id) == ["s1", "s2", "s3"])
        #expect(refs.map(\.documentID) == ["Runbook", "Runbook", "Deadlines"])
        #expect(refs.orderedDocuments() == ["Runbook", "Deadlines"])
    }

    // MARK: - Every arm of the decision table

    @Test("a robust admission is recorded and passes")
    func robustAdmits() {
        var trace = PipelineTrace()
        let result = PreModelPipeline.act(on: report(.robust, probeCount: 7), sourceCount: 3, trace: &trace)
        #expect(result == .admitted)
        guard case let .ran(detail) = trace.outcome(for: .verdictStability) else {
            Issue.record("expected .ran, got \(String(describing: trace.outcome(for: .verdictStability)))")
            return
        }
        #expect(detail.contains("survives"))
        #expect(detail.contains("7 re-runs"))
    }

    /// The one refusal. Two weak sides landing close is two matching failures cancelling, and the
    /// app cannot tell agreement from contradiction on that evidence.
    @Test("offsetting weakness under a contested ruling refuses, and it reaches the user")
    func offsettingWeaknessRefuses() {
        var trace = PipelineTrace()
        let verdict = StabilityVerdict.coincidental(.offsettingWeakness(affirming: 0.75, denying: 0.75))
        let result = PreModelPipeline.act(on: report(verdict, label: "contested"), sourceCount: 2, trace: &trace)

        guard case let .refused(refusal) = result else {
            Issue.record("expected .refused, got \(result)")
            return
        }
        #expect(refusal.stage == .verdictStability)
        #expect(!refusal.headline.isEmpty)
        #expect(refusal.explanation.contains("0.75"))
        #expect(refusal.explanation.contains("cancelling out"))
        #expect(refusal.recovery == .openSettings(field: "Retrieval"))
        #expect(trace.outcome(for: .verdictStability)?.isRefusal == true)
    }

    /// The same finding under an `answerable` ruling is not grounds to refuse. There is no
    /// conflict claim for it to undermine, and the numbers mean only that support was thin —
    /// which is the gate's call. Refusing here blocked a legitimate question against this app's
    /// own budget corpus, and `HybridRetrievalTests` caught it.
    @Test("offsetting weakness under an answerable ruling is recorded, not refused")
    func offsettingWeaknessOnAnswerableRecords() {
        var trace = PipelineTrace()
        let verdict = StabilityVerdict.coincidental(.offsettingWeakness(affirming: 0.30, denying: 0.20))
        let result = PreModelPipeline.act(on: report(verdict), sourceCount: 3, trace: &trace)
        #expect(result == .admitted)
        guard case let .ran(detail) = trace.outcome(for: .verdictStability) else {
            Issue.record("expected .ran")
            return
        }
        #expect(detail.contains("recorded, not refused"))
        #expect(detail.contains("answerable"))
    }

    /// Recorded rather than refused: answering from one document is ordinary. Presenting it as
    /// corroborated would not be, and the trace is where that distinction is kept.
    @Test("single-document corroboration is recorded, not refused")
    func singleDocumentAdmits() {
        var trace = PipelineTrace()
        let verdict = StabilityVerdict.coincidental(
            .singleDocumentCorroboration(documentID: "Runbook", passages: 3)
        )
        let result = PreModelPipeline.act(on: report(verdict), sourceCount: 3, trace: &trace)
        #expect(result == .admitted)
        guard case let .ran(detail) = trace.outcome(for: .verdictStability) else {
            Issue.record("expected .ran")
            return
        }
        #expect(detail.contains("Runbook"))
        #expect(detail.contains("one source, not several"))
    }

    @Test("a pivotal admission names how much it depends on")
    func pivotalAdmits() {
        var trace = PipelineTrace()
        let verdict = StabilityVerdict.pivotal(items: [], documents: ["Runbook"])
        let result = PreModelPipeline.act(on: report(verdict), sourceCount: 4, trace: &trace)
        #expect(result == .admitted)
        guard case let .ran(detail) = trace.outcome(for: .verdictStability) else {
            Issue.record("expected .ran")
            return
        }
        // The case the package exists for: nothing pivots at passage level, one document does.
        #expect(detail.contains("no passage"))
        #expect(detail.contains("1 document(s)"))
    }

    @Test("a knife-edge admission reports its distance from the threshold")
    func knifeEdgeAdmits() {
        var trace = PipelineTrace()
        let result = PreModelPipeline.act(on: report(.knifeEdge(margin: 0.02)), sourceCount: 2, trace: &trace)
        #expect(result == .admitted)
        guard case let .ran(detail) = trace.outcome(for: .verdictStability) else {
            Issue.record("expected .ran")
            return
        }
        #expect(detail.contains("0.02"))
    }

    @Test("too few passages is skipped rather than reported as stable")
    func tooFewIsSkipped() {
        var trace = PipelineTrace()
        let verdict = StabilityVerdict.undetermined(.tooFewItems(count: 1, required: 2))
        let result = PreModelPipeline.act(on: report(verdict), sourceCount: 1, trace: &trace)
        #expect(result == .admitted)
        guard case let .skipped(reason) = trace.outcome(for: .verdictStability) else {
            Issue.record("expected .skipped")
            return
        }
        #expect(reason.contains("1 passage(s), 2 needed"))
    }

    @Test("empty evidence is skipped")
    func emptyIsSkipped() {
        var trace = PipelineTrace()
        let result = PreModelPipeline.act(
            on: report(.undetermined(.emptyEvidence)),
            sourceCount: 0,
            trace: &trace
        )
        #expect(result == .admitted)
        #expect(trace.outcome(for: .verdictStability) == .skipped(reason: "no evidence to perturb"))
    }

    /// A gate that answers the same with and without evidence has no dependency to measure.
    /// Reporting that as stability would be the most misleading thing this stage could say.
    @Test("a gate that ignores its evidence is a no-op, not a pass")
    func degenerateIsNoOp() {
        var trace = PipelineTrace()
        let verdict = StabilityVerdict.undetermined(.degenerateProbe(label: "answerable"))
        let result = PreModelPipeline.act(on: report(verdict), sourceCount: 3, trace: &trace)
        #expect(result == .admitted)
        guard case let .noOp(reason) = trace.outcome(for: .verdictStability) else {
            Issue.record("expected .noOp")
            return
        }
        #expect(reason.contains("answerable"))
    }

    // MARK: - Through the real pipeline

    @Test("a turn with no passages skips the stage instead of measuring nothing")
    func noSourcesSkips() async {
        let subject = await pipeline()
        var trace = PipelineTrace()
        let result = await subject.measureVerdictStability(of: [], for: "hello", trace: &trace)
        #expect(result == .admitted)
        guard case let .skipped(reason) = trace.outcome(for: .verdictStability) else {
            Issue.record("expected .skipped")
            return
        }
        #expect(reason.contains("no retrieved passages"))
    }

    /// End to end against the app's real gate rather than a synthetic report: two chunks of one
    /// page, measured by the same engine the pipeline gates with.
    @Test("two chunks of one document are measured through the real gate")
    func chunkedDocumentIsMeasuredThroughRealGate() async {
        let subject = await pipeline()
        var trace = PipelineTrace()
        let sources = [
            source("s1", title: "Runbook", snippet: "The client retries a request when the provider returns 429."),
            source("s2", title: "Runbook", snippet: "Retry policies apply to idempotent request handlers only.")
        ]
        let result = await subject.measureVerdictStability(
            of: sources,
            for: "which requests were retried",
            trace: &trace
        )
        #expect(result == .admitted)
        // A stage with no record is indistinguishable from a stage that is not wired in.
        #expect(trace.outcome(for: .verdictStability) != nil)
    }
}
