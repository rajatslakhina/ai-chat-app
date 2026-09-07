import AbstentionPolicyKit
import Foundation

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

    /// What each stage found but did not block on.
    ///
    /// A stage that raises a reservation and returns `.admitted` currently has nowhere to put the
    /// reservation, so it is written into a `detail` string and thrown away. Independence merging
    /// two passages, stability finding support thin on both sides, the answerability gate
    /// recording a coverage gap it does not trust its own recall to refuse on — all real, all
    /// discarded. They live here so `abstentionArbiter` can ask whether several of them together
    /// mean something none of them meant alone.
    private(set) var reservations: [AbstentionSignal] = []

    /// The exploration admission this turn was answered under, if it was.
    ///
    /// A typed field rather than something read back out of a `detail` string. The stage that
    /// admits the turn and the stage that learns the verdict are at opposite ends of the pipeline,
    /// and the id is the only thing that connects them; recovering it by parsing prose is how a
    /// label ends up attached to the wrong admission.
    private(set) var explorationID: String?

    /// The id `PanelHistoryStore` filed this turn's gate readings under, if any were filed.
    ///
    /// The same reason `explorationID` is here. The stage that records what the gates said runs
    /// before the model and the stage that learns whether the answer held up runs after it, and
    /// this id is the only thing tying the two to the same turn. Attaching an outcome to
    /// "whatever the store saw last" would be correct only until two turns overlap.
    private(set) var panelTurnID: String?

    init(records: [StageRecord] = []) {
        self.records = records
    }

    /// Note that this turn was answered as a deliberate exploration.
    mutating func noteExploration(id: String) {
        explorationID = id
    }

    /// Note which panel observation this turn's gate readings were filed as.
    mutating func notePanelTurn(id: String) {
        panelTurnID = id
    }

    mutating func record(_ stage: PipelineStage, _ outcome: StageOutcome, durationMs: Int = 0) {
        records.append(StageRecord(stage: stage, outcome: outcome, durationMs: durationMs))
    }

    /// Files one stage's reading, blocking or not.
    ///
    /// Separate from `record` rather than derived from it. A `StageOutcome` says what the stage
    /// *did*; a reading says what it *found*, and the two are not the same — `.ran` covers both a
    /// clean pass and a pass that noticed something, and collapsing them would hand the arbiter a
    /// clear signal for every stage that noticed a problem and carried on.
    mutating func reserve(_ signal: AbstentionSignal) {
        reservations.append(signal)
    }

    /// Replaces the filed readings with one per independent voice.
    ///
    /// A replacement rather than a parallel store. The arbiter must rule on exactly one array or
    /// its explanation can describe a set of findings the decision was not made from — the second
    /// source of truth this ecosystem removed by hand on 08-18, reintroduced by the back door.
    mutating func deflateReservations(to voices: [AbstentionSignal]) {
        reservations = voices
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
