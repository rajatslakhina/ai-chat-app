import Foundation

/// Every stage one user message passes through, in the order it passes through them.
///
/// One case per package in the ecosystem, which is the point: the ordering below *is* the
/// architecture, and a stage that has no case here is a package that is not really wired in.
/// `CaseIterable` lets the Diagnostics screen enumerate all of them and show which ones actually
/// ran, so a package that silently did nothing is visible as a gap rather than invisible.
enum PipelineStage: String, CaseIterable, Sendable, Identifiable {
    // Before the model sees anything
    case promptTemplate
    case guardrailInput
    case semanticRoute
    case idempotencyGuard
    case cacheLookup
    case memoryRecall
    case retrieval
    /// The lexical half of retrieval, and the fusion that reconciles it with the dense half.
    case lexicalRetrieval
    case rankFusion
    /// Whether the passages that survived fusion agree with each other.
    case sourceConflict
    case contextCompaction

    // Deciding whether the turn is allowed to happen at all
    /// Which inflectional families the answerability gate will read the evidence through.
    /// Produces the audit trail for the stage below it: without it, a gate that changes its
    /// mind about the same corpus cannot be asked why.
    case evidenceKeying
    /// Whether the passages that survived can answer the question that was asked.
    /// Runs after compaction so it judges the evidence the model will actually receive.
    case answerabilityGate
    /// Whether the passages the gate just admitted are still entitled to speak.
    /// Runs before independence and stability because it needs nothing from either — only the
    /// dates the corpus already carried — and because a ruling that rests on an expired snapshot
    /// is not worth measuring the provenance of.
    case temporalValidity
    /// Whether the gate's ruling would survive its own evidence being taken apart.
    /// Runs only after an admission, because there is no point measuring the stability of a
    /// verdict the app already refused to act on.
    /// How many independent sources are actually behind the passages the gate just admitted.
    /// Runs before stability, because stability's document-level pass is only as good as the
    /// document identifiers it is handed, and this app's retrieval layer supplies none.
    case sourceIndependence
    case verdictStability
    case workloadProfile
    case costForecast
    case budgetReserve

    // Getting an answer
    case retryPolicy
    case providerRouting
    case streamAggregation
    case sessionDelivery

    // Making sense of the answer
    case structuredDecode
    case outputRepair
    case schemaMigration
    case grounding
    /// Deciding what a claim *is*, before anything judges one.
    case claimSegmentation
    /// Whether each grounded claim actually *agrees* with the passage it matched.
    case claimConsistency
    /// Whether each claim is supported by the document the answer *said* it came from.
    case citationBinding
    /// Whether each claim can be read on its own, or only makes sense inside the answer.
    case claimDecontextualization

    // Acting on the answer
    case toolAuthority
    case toolDispatch
    case agentLoop
    case batchInference
    /// Recording the finished turn as a golden-case candidate for the eval suite.
    case transcriptCapture

    // Accounting for what happened
    case guardrailOutput
    case metering
    case budgetSettle
    case tracing

    var id: String { rawValue }

    /// The package that owns this stage, shown in Diagnostics so the mapping is explicit.
    var package: String {
        switch self {
        case .promptTemplate: return "PromptTemplateKit"
        case .lexicalRetrieval, .rankFusion: return "SpotlightRAGKit"
        case .transcriptCapture: return "EvalHarness"
        case .guardrailInput, .guardrailOutput: return "GuardrailKit"
        case .semanticRoute: return "SemanticRouterKit"
        case .idempotencyGuard: return "IdempotencyKit"
        case .cacheLookup: return "ResponseCacheKit"
        case .memoryRecall: return "AgentMemoryKit"
        case .retrieval: return "RetrievalKit"
        case .contextCompaction: return "ContextCompactionKit"
        case .workloadProfile: return "WorkloadProfilerKit"
        case .costForecast: return "CostEstimatorKit"
        case .budgetReserve, .budgetSettle: return "QuotaGovernorKit"
        case .retryPolicy: return "RetryPolicyKit"
        case .providerRouting: return "ProviderGatewayKit"
        case .streamAggregation: return "StreamAggregatorKit"
        case .sessionDelivery: return "RealtimeSessionKit"
        case .structuredDecode: return "StructuredOutputKit"
        case .outputRepair: return "OutputRepairKit"
        case .schemaMigration: return "SchemaMigrationKit"
        case .grounding: return "GroundingKit"
        case .claimSegmentation: return "ClaimSegmenterKit"
        case .claimConsistency: return "ClaimConsistencyKit"
        case .citationBinding: return "CitationBindingKit"
        case .claimDecontextualization: return "ClaimDecontextualizerKit"
        case .sourceConflict: return "SourceConflictKit"
        case .evidenceKeying: return "MorphologyMatchKit"
        case .answerabilityGate: return "AnswerabilityKit"
        case .temporalValidity: return "TemporalValidityKit"
        case .sourceIndependence: return "SourceIndependenceKit"
        case .verdictStability: return "EvidenceSensitivityKit"
        case .toolAuthority: return "ToolAuthorityKit"
        case .toolDispatch: return "ToolRegistryKit"
        case .agentLoop: return "AgentLoopKit"
        case .batchInference: return "BatchInferenceKit"
        case .metering: return "TokenMeterKit"
        case .tracing: return "TraceKit"
        }
    }

    /// What this stage is for, in the words a Diagnostics reader needs.
    var title: String {
        switch self {
        case .promptTemplate: return "Prompt template"
        case .guardrailInput: return "Input guardrail"
        case .semanticRoute: return "Semantic route"
        case .idempotencyGuard: return "Idempotency guard"
        case .cacheLookup: return "Cache lookup"
        case .memoryRecall: return "Memory recall"
        case .retrieval: return "Retrieval"
        case .lexicalRetrieval: return "Lexical retrieval"
        case .rankFusion: return "Rank fusion"
        case .transcriptCapture: return "Transcript capture"
        case .contextCompaction: return "Context compaction"
        case .evidenceKeying: return "Evidence keying"
        case .answerabilityGate: return "Answerability gate"
        case .temporalValidity: return "Temporal validity"
        case .sourceIndependence: return "Source independence"
        case .verdictStability: return "Verdict stability"
        case .workloadProfile: return "Workload profile"
        case .costForecast: return "Cost forecast"
        case .budgetReserve: return "Budget reserve"
        case .retryPolicy: return "Retry policy"
        case .providerRouting: return "Provider routing"
        case .streamAggregation: return "Stream aggregation"
        case .sessionDelivery: return "Session delivery"
        case .structuredDecode: return "Structured decode"
        case .outputRepair: return "Output repair"
        case .schemaMigration: return "Schema migration"
        case .grounding: return "Grounding"
        case .claimSegmentation: return "Claim segmentation"
        case .claimConsistency: return "Claim consistency"
        case .citationBinding: return "Citation binding"
        case .claimDecontextualization: return "Claim decontextualization"
        case .sourceConflict: return "Source conflict"
        case .toolAuthority: return "Tool authority"
        case .toolDispatch: return "Tool dispatch"
        case .agentLoop: return "Agent loop"
        case .batchInference: return "Batch inference"
        case .guardrailOutput: return "Output guardrail"
        case .metering: return "Metering"
        case .budgetSettle: return "Budget settle"
        case .tracing: return "Tracing"
        }
    }
}

/// A refusal, in the shape the chat UI can render.
///
/// Every field exists because a refusal the user cannot act on is barely better than a silent
/// one: `headline` says what happened, `explanation` says why, and `recovery` says what to do
/// about it. A stage that refuses without filling these in fails review.
struct Refusal: Sendable, Equatable {
    let stage: PipelineStage
    let headline: String
    let explanation: String
    let recovery: RecoveryAction?

    enum RecoveryAction: Sendable, Equatable {
        case openSettings(field: String)
        case retryLater(after: Duration?)
        case switchModel
        case shortenConversation
        case approveTool(name: String)
        case addCredit
    }

    /// The button title for `recovery`, or nil when nothing can be done from here.
    var recoveryTitle: String? {
        switch recovery {
        case .openSettings: return "Open Settings"
        case let .retryLater(after):
            guard let after else { return "Try again" }
            return "Try again in \(after.components.seconds)s"
        case .switchModel: return "Choose another model"
        case .shortenConversation: return "Start a new conversation"
        case let .approveTool(name): return "Approve \(name)"
        case .addCredit: return "Add credit"
        case nil: return nil
        }
    }
}

/// What a stage did.
///
/// `refused` is deliberately distinct from `failed`. A refusal is the system working: a budget
/// that says no, a guardrail that redacts, an authority check that declines a tool. A failure is
/// the system breaking. Collapsing them into one case is how a product ends up telling a user
/// "something went wrong" when the truthful answer was "you are out of budget" — and the first
/// message is unactionable while the second is not.
enum StageOutcome: Sendable, Equatable {
    /// Ran and changed something. `detail` is shown in Diagnostics.
    case ran(detail: String)
    /// Ran and correctly did nothing — a cache miss, no tools requested, nothing to compact.
    case noOp(reason: String)
    /// Deliberately not run, because configuration or the request shape made it inapplicable.
    case skipped(reason: String)
    /// The stage said no. This MUST reach the user.
    case refused(Refusal)
    /// The stage broke.
    case failed(message: String)

    var isRefusal: Bool {
        if case .refused = self { return true }
        return false
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    /// One line for the Diagnostics list.
    var summary: String {
        switch self {
        case let .ran(detail): return detail
        case let .noOp(reason): return reason
        case let .skipped(reason): return reason
        case let .refused(refusal): return refusal.headline
        case let .failed(message): return message
        }
    }
}

/// One stage's record within a single send.
struct StageRecord: Sendable, Equatable, Identifiable {
    let stage: PipelineStage
    let outcome: StageOutcome
    /// Milliseconds this stage occupied. Measured, not estimated.
    let durationMs: Int

    var id: String { stage.rawValue }
}

/// The full record of what the packages did to one message.
///
/// This is what the Diagnostics tab renders, and it is assembled during a real send rather than
/// reconstructed afterwards — a reconstruction would be a plausible story about the run instead
/// of the run itself.
struct PipelineTrace: Sendable, Equatable {
    private(set) var records: [StageRecord] = []

    init(records: [StageRecord] = []) {
        self.records = records
    }

    mutating func record(_ stage: PipelineStage, _ outcome: StageOutcome, durationMs: Int = 0) {
        records.append(StageRecord(stage: stage, outcome: outcome, durationMs: durationMs))
    }

    /// The first refusal, which is the one that stopped the turn.
    var refusal: Refusal? {
        for record in records {
            if case let .refused(refusal) = record.outcome { return refusal }
        }
        return nil
    }

    var failures: [StageRecord] { records.filter(\.outcome.isFailure) }

    /// Stages that never ran at all — the ones a reader of Diagnostics would otherwise have to
    /// notice by their absence.
    var unreached: [PipelineStage] {
        let seen = Set(records.map(\.stage))
        return PipelineStage.allCases.filter { !seen.contains($0) }
    }

    var totalDurationMs: Int { records.reduce(0) { $0 + $1.durationMs } }

    func outcome(for stage: PipelineStage) -> StageOutcome? {
        records.first { $0.stage == stage }?.outcome
    }
}
