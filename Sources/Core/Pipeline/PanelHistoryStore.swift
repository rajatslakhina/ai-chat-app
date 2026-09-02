import AbstentionPolicyKit
import EffectiveVoteKit
import Foundation
import ProxyLabelKit

/// What the four evidence gates said, turn after turn.
///
/// `PreModelPipeline.dependenceGraph` declares how much two of those gates overlap, and that
/// declaration changes what the arbiter counts. Measuring it needs the one thing a single turn
/// cannot supply: the same judges ruling on many different turns. This is where those rulings
/// accumulate.
///
/// It is deliberately not a general event log. Only turns where at least one gate actually filed a
/// reading are recorded, because a turn no gate spoke on is not an observation of the panel — it is
/// a turn that did not need one, which is the same distinction `SignalReading.unavailable` exists
/// to preserve.
actor PanelHistoryStore {
    static let shared = PanelHistoryStore()

    private let ledger = PanelLedger()
    private var turnCount = 0
    private var judgements: [Judgement] = []
    private var signals: [OutcomeSignal] = []

    init() {}

    /// Records one turn's readings. Gates that filed nothing are left out of the observation
    /// rather than entered as agreement, because a judge that was never asked has not agreed with
    /// anyone.
    @discardableResult
    func record(_ readings: [AbstentionSignal]) async -> String? {
        guard !readings.isEmpty else { return nil }
        turnCount += 1
        let id = "turn-\(turnCount)"
        var verdicts: [JudgeIdentity: Verdict] = [:]
        for reading in readings {
            verdicts[JudgeIdentity(reading.origin.rawValue)] = Self.verdict(for: reading.reading)
            judgements.append(
                Judgement(
                    judge: JudgeID(reading.origin.rawValue),
                    item: ItemID(id),
                    affirmed: Self.verdict(for: reading.reading) == .affirm
                )
            )
        }
        await ledger.record(PanelObservation(id: id, verdicts: verdicts, truth: nil))
        return id
    }

    /// Files what happened to a turn's answer after it shipped.
    ///
    /// The scope is `.item` and not negotiable: `checkConsistency` rules on the **answer**, so one
    /// wrong ruling is wrong about every gate that admitted the evidence behind it. Recording it
    /// as though it named a single gate would erase the one fact that decides how far the labels
    /// can be trusted.
    func recordOutcome(turn: String, contradicted: Bool) {
        signals.append(
            OutcomeSignal(
                item: ItemID(turn),
                kind: .laterContradiction,
                scope: .item,
                indicatesFailure: contradicted
            )
        )
    }

    /// The correctness labels those outcomes imply, or an empty array while none have arrived.
    var labelProposals: [LabelProposal] {
        ContradictionLabeler().propose(judgements: judgements, signals: signals)
    }

    /// How many turns have had an outcome filed against them.
    var outcomeCount: Int { signals.count }

    var history: ObservationHistory {
        get async { await ledger.history }
    }

    /// A gate that found nothing is a vote to proceed; one holding a concern or a refusal is a vote
    /// against. `unavailable` stays an abstention: a gate that could not form a view has not
    /// objected, and counting it as one would invent agreement with every gate that did.
    static func verdict(for reading: SignalReading) -> Verdict {
        if reading.isClear { return .affirm }
        if reading.isRefusal || reading.concernSeverity != nil { return .deny }
        return .abstain
    }

    /// The declared strengths, read off the graph the arbiter actually uses rather than copied.
    ///
    /// Copying them would let the two drift apart silently, which would make this stage measure a
    /// declaration nothing in the pipeline is standing on.
    static func declaredStrengths() -> [JudgePair: Double] {
        var declared: [JudgePair: Double] = [:]
        for edge in PreModelPipeline.dependenceGraph.edges where !edge.isSelfEdge {
            let pair = JudgePair(JudgeIdentity(edge.a.rawValue), JudgeIdentity(edge.b.rawValue))
            declared[pair] = edge.strength
        }
        return declared
    }
}
