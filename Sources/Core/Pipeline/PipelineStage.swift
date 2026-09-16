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
    /// See rationale in `PipelineStage+Rationale.swift`.
    case evidenceKeying
    /// See rationale in `PipelineStage+Rationale.swift`.
    case answerabilityGate
    /// See rationale in `PipelineStage+Rationale.swift`.
    case temporalValidity
    /// See rationale in `PipelineStage+Rationale.swift`.
    case sourceIndependence
    case verdictStability
    /// See rationale in `PipelineStage+Rationale.swift`.
    case signalDependence
    /// See rationale in `PipelineStage+Rationale.swift`.
    case abstentionArbiter
    /// See rationale in `PipelineStage+Rationale.swift`.
    case conformalGate
    /// See rationale in `PipelineStage+Rationale.swift`.
    case censoredFeedback
    /// See rationale in `PipelineStage+Rationale.swift`.
    case explorationChannel
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
    /// See rationale in `PipelineStage+Rationale.swift`.
    case labelReturn

    /// See rationale in `PipelineStage+Rationale.swift`.
    case delaySignal

    /// See rationale in `PipelineStage+Rationale.swift`.
    case delayShape

    /// See rationale in `PipelineStage+Rationale.swift`.
    case delayCurve

    /// See rationale in `PipelineStage+Rationale.swift`.
    case curveDivergence

    /// See rationale in `PipelineStage+Rationale.swift`.
    case labelClock

    /// See rationale in `PipelineStage+Rationale.swift`.
    case effectiveVote
    /// See rationale in `PipelineStage+Rationale.swift`.
    case proxyLabel
    /// See rationale in `PipelineStage+Rationale.swift`.
    case sampleWidth
    /// See rationale in `PipelineStage+Rationale.swift`.
    case familyError

    /// See rationale in `PipelineStage+Rationale.swift`.
    case effectiveComparison

    /// See rationale in `PipelineStage+Rationale.swift`.
    case observedNull

    /// See rationale in `PipelineStage+Rationale.swift`.
    case chanceAgreement

    /// See rationale in `PipelineStage+Rationale.swift`.
    case panelDesign

    /// See rationale in `PipelineStage+Rationale.swift`.
    case squareDesign

    /// See rationale in `PipelineStage+Rationale.swift`.
    case associationFit
    /// See rationale in `PipelineStage+Rationale.swift`.
    case associationTransport
    /// See rationale in `PipelineStage+Rationale.swift`.
    case exactAssociation
    /// See rationale in `PipelineStage+Rationale.swift`.
    case conditioningCost
    /// See rationale in `PipelineStage+Rationale.swift`.
    case unconditionalExact
    /// See rationale in `PipelineStage+Rationale.swift`.
    case totalFixedExact
    case restrictionRule
    case repeatedSuccess
    /// Whether this app's live gate-affirmation stream already has enough evidence to call the
    /// session's affirm rate healthy or unhealthy, without waiting for a fixed sample size.
    ///
    /// `repeatedSuccess` answers a fixed-`k` question over the same panel and needs `k` cast
    /// verdicts before it will speak. This stage answers a different one — has the *sequential*
    /// evidence crossed a boundary yet — and can speak, refuse to speak, or keep watching after
    /// any number of turns, because Wald's SPRT is valid at any data-dependent stopping time and
    /// a fixed-`k` test is not. It is the anytime-valid complement to that fixed-point read, not
    /// a replacement for it.
    ///
    /// A session this app actually runs rarely reaches the boundary — a chat client's gates fire
    /// on a small minority of turns — and that is reported honestly rather than forced: most
    /// sessions read `.ran` with a "still watching" decision, and a boundary crossing is real
    /// news, not routine. Like its metadata siblings it produces no `Refusal`: it reports on this
    /// app's own measurements, and there is nothing in it for a user to undo.
    case sequentialBound

    /// See rationale in `PipelineStage+Rationale.swift`.
    case confidenceSequence

    // Acting on the answer
    case toolAuthority
    /// See rationale in `PipelineStage+Rationale.swift`.
    case selectionTrust
    /// See rationale in `PipelineStage+Rationale.swift`.
    case argumentAttribution
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
}
