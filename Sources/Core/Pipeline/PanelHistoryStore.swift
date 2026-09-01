import AbstentionPolicyKit
import EffectiveVoteKit
import Foundation

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

    init() {}

    /// Records one turn's readings. Gates that filed nothing are left out of the observation
    /// rather than entered as agreement, because a judge that was never asked has not agreed with
    /// anyone.
    func record(_ readings: [AbstentionSignal]) async {
        guard !readings.isEmpty else { return }
        turnCount += 1
        var verdicts: [JudgeIdentity: Verdict] = [:]
        for reading in readings {
            verdicts[JudgeIdentity(reading.origin.rawValue)] = Self.verdict(for: reading.reading)
        }
        await ledger.record(
            PanelObservation(id: "turn-\(turnCount)", verdicts: verdicts, truth: nil)
        )
    }

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
