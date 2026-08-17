import AgentMemoryKit
import ContextCompactionKit
import Foundation
import GuardrailKit
import PromptTemplateKit
import ResponseCacheKit
import RetrievalKit
import SemanticRouterKit
import Testing
@testable import AIChatApp

/// The temporal stage, driven through every arm it can reach.
///
/// The stage is `nonisolated` and reads only immutable statics, so these call it directly rather
/// than through `prepare` — the same shape `SourceIndependenceStageTests` uses, and for the same
/// reason: a pipeline-level test would have to arrange retrieval to return a specific corpus to
/// reach an arm, and an arm reachable only by accident is an arm nobody can test.
@Suite("Temporal validity stage")
struct TemporalValidityStageTests {
    private func source(
        _ id: String,
        subject: String?,
        daysOld: Int?,
        text: String,
        title: String? = nil
    ) -> RetrievedSource {
        RetrievedSource(
            id: id,
            title: title ?? id,
            snippet: text,
            relevancePercent: 50,
            subject: subject,
            observedAt: daysOld.map { Date().addingTimeInterval(-Double($0) * 86_400) }
        )
    }

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

    @Test("no passages is a skip, not a finding")
    func noPassages() async {
        var trace = PipelineTrace()
        let refusal = await pipeline().establishTemporalValidity(
            question: "anything",
            sources: [],
            trace: &trace
        )
        #expect(refusal == nil)
        guard case .skipped? = trace.outcome(for: .temporalValidity) else {
            Issue.record("expected a skip, got \(String(describing: trace.outcome(for: .temporalValidity)))")
            return
        }
    }

    @Test("a corpus carrying no dates records that it checked nothing")
    func undatedCorpus() async {
        var trace = PipelineTrace()
        let sources = [
            source("a", subject: nil, daysOld: nil, text: "the queue depth bounds a burst"),
            source("b", subject: nil, daysOld: nil, text: "a burst above the queue depth is queued")
        ]
        let refusal = await pipeline().establishTemporalValidity(
            question: "what happens to a burst that exceeds the queue depth",
            sources: sources,
            trace: &trace
        )
        #expect(refusal == nil)
        guard case .noOp(let reason)? = trace.outcome(for: .temporalValidity) else {
            Issue.record("expected a noOp, got \(String(describing: trace.outcome(for: .temporalValidity)))")
            return
        }
        #expect(reason.contains("none carrying both a subject and a date"))
    }

    @Test("current evidence passes and the trace says how much of it was entitled")
    func currentEvidence() async {
        var trace = PipelineTrace()
        let sources = [
            source(
                "fresh",
                subject: "app-budgets",
                daysOld: 3,
                text: "Settings can cap what the account spends inside one calendar month."
            )
        ]
        let refusal = await pipeline().establishTemporalValidity(
            question: "can I cap what the account spends in a calendar month",
            sources: sources,
            trace: &trace
        )
        #expect(refusal == nil)
        guard case .ran(let detail)? = trace.outcome(for: .temporalValidity) else {
            Issue.record("expected a ran, got \(String(describing: trace.outcome(for: .temporalValidity)))")
            return
        }
        #expect(detail.contains("1 of 1 passage(s) entitled"))
    }

    @Test("an admission that only survives on expired evidence is refused")
    func staleAdmissionRefused() async {
        var trace = PipelineTrace()
        // `openrouter-catalog` carries a 30-day window, so a 400-day-old snapshot has run out.
        // The one current passage is about something else, so withholding the snapshot leaves
        // nothing that answers the question.
        let sources = [
            source(
                "catalog",
                subject: "openrouter-catalog",
                daysOld: 400,
                text: "The model picker lists every OpenRouter model with published per-token pricing.",
                title: "Choosing a model"
            ),
            source(
                "budgets",
                subject: "app-budgets",
                daysOld: 1,
                text: "Spend is stored in microcents.",
                title: "Budgets and spend"
            )
        ]
        let refusal = await pipeline().establishTemporalValidity(
            question: "which models does the picker list with published per-token pricing",
            sources: sources,
            trace: &trace
        )
        #expect(refusal?.stage == .temporalValidity)
        #expect(refusal?.headline == "This answer would rest on out-of-date sources")
        #expect(trace.outcome(for: .temporalValidity)?.isRefusal == true)
    }

    @Test("a dated passage whose subject nobody declared is undetermined, not stale")
    func undeclaredSubjectIsUndetermined() async {
        var trace = PipelineTrace()
        // A corpus this app does not own: the passage is dated, but no volatility was declared
        // for its subject, so nothing can be said about whether it has run out. The stage must
        // not invent a window, and must not read "not established" as "fine".
        let sources = [
            source(
                "external",
                subject: "someone-elses-corpus",
                daysOld: 5000,
                text: "A burst that exceeds the queue depth is held rather than rejected."
            )
        ]
        let refusal = await pipeline().establishTemporalValidity(
            question: "what happens to a burst that exceeds the queue depth",
            sources: sources,
            trace: &trace
        )
        #expect(refusal == nil)
        guard case .noOp(let reason)? = trace.outcome(for: .temporalValidity) else {
            Issue.record("expected a noOp, got \(String(describing: trace.outcome(for: .temporalValidity)))")
            return
        }
        #expect(reason == "no passage's standing was established")
    }

    @Test("the refusal names the titles the user can see, not the internal ids")
    func refusalNamesTitles() {
        let sources = [
            source("catalog", subject: "openrouter-catalog", daysOld: 400, text: "x", title: "Choosing a model"),
            source("budgets", subject: "app-budgets", daysOld: 1, text: "y", title: "Budgets and spend")
        ]
        let refusal = PreModelPipeline.refusalForStaleAdmission(withheld: ["catalog"], sources: sources)
        #expect(refusal.stage == .temporalValidity)
        #expect(refusal.headline == "This answer would rest on out-of-date sources")
        #expect(refusal.explanation.contains("Choosing a model"))
        #expect(!refusal.explanation.contains("Budgets and spend"))
        #expect(refusal.explanation.contains("1 of the 2 passages"))
        #expect(refusal.recovery == .shortenConversation)
    }

    @Test("a passage with no subject gets one that cannot supersede anything")
    func unattributedSubjectIsIsolated() {
        let first = PreModelPipeline.observation(
            for: source("p1", subject: nil, daysOld: 5, text: "x")
        )
        let second = PreModelPipeline.observation(
            for: source("p2", subject: nil, daysOld: 900, text: "y")
        )
        #expect(first.subject != second.subject)
        #expect(first.subject.rawValue == "unattributed:p1")
        #expect(second.observedAt != nil)
    }

    @Test("a passage the corpus never dated stays undated")
    func undatedStaysUndated() {
        let observation = PreModelPipeline.observation(
            for: source("p", subject: "app-tools", daysOld: nil, text: "x")
        )
        #expect(observation.observedAt == nil)
        #expect(observation.subject.rawValue == "app-tools")
    }

    @Test("the catalog is built from the corpus's own declarations, with no fallback")
    func catalogMirrorsCorpus() {
        let catalog = PreModelPipeline.temporalAnalyzer.catalog
        // The three self-describing documents ship with the binary and cannot expire.
        #expect(catalog.volatility(for: .init("app-budgets"))?.validityWindow == nil)
        #expect(catalog.volatility(for: .init("app-tools"))?.validityWindow == nil)
        // The third-party catalog snapshot can, and the window is the corpus's number rather
        // than one restated here — a literal would pass while the two drifted apart.
        #expect(
            catalog.volatility(for: .init("openrouter-catalog"))?.validityWindow
                == AppKnowledge.volatility["models"]?.window
        )
        #expect(catalog.volatility(for: .init("openrouter-catalog"))?.validityWindow != nil)
        // Nothing is declared for a corpus this app does not own, and there is no fallback that
        // would invent an expiry date for it.
        #expect(catalog.volatility(for: .init("something-else")) == nil)
        #expect(catalog.fallback == nil)
    }

    @Test("the corpus declares a subject and a window for every document it ships")
    func everyDocumentDeclared() {
        for document in AppKnowledge.documents {
            #expect(
                AppKnowledge.volatility[document.id.rawValue] != nil,
                "\(document.id.rawValue) ships with no temporal declaration"
            )
        }
    }

    @Test("retrieval metadata carries the subject and date the temporal pass reads")
    func metadataCarriesProvenance() {
        let documents = AppKnowledge.retrievalDocuments
        guard let models = documents.first(where: { $0.id == "models" }) else {
            Issue.record("the models document is missing from the retrieval corpus")
            return
        }
        #expect(models.metadata["subject"] == "openrouter-catalog")
        #expect(models.metadata["observedAt"] == String(AppKnowledge.epoch.timeIntervalSince1970))
    }
}
