import AbstentionPolicyKit
import Foundation
import SignalDependenceAbstention
import SignalDependenceKit

extension PreModelPipeline {
    /// What these four gates share, and why each edge is here.
    ///
    /// Only relationships that are true *by construction* are declared. A guessed edge in this
    /// graph loosens the arbiter, and the arbiter is the one place in this pipeline that can stop
    /// a turn nobody else would — so anything short of provable does not go in.
    ///
    /// The derivation is the load-bearing one. `EvidenceSensitivityKit` measures stability by
    /// re-running the answerability gate with passages withheld; its finding is a function of that
    /// gate's verdict. When both file a concern, that is not two judges agreeing, it is one engine
    /// run twice, and an arbiter set to `concurringOrigins: 2` would stop the turn on it.
    ///
    /// Independence and temporal validity are declared as sharing an input because they are handed
    /// the same `[RetrievedSource]` — one reads its locators and text, the other its dates, but a
    /// corpus that is wrong is wrong for both of them. `sharedInput`'s 0.6 default sits above the
    /// 0.5 collapse threshold, which is deliberate: two readings of one corpus are one corpus's
    /// opinion.
    static let dependenceGraph = DependenceGraph(edges: [
        DependenceEdge.derives(
            DependenceOrigin(ReservationOrigin.stability.rawValue),
            from: DependenceOrigin(ReservationOrigin.answerability.rawValue)
        ),
        DependenceEdge(
            DependenceOrigin(ReservationOrigin.independence.rawValue),
            DependenceOrigin(ReservationOrigin.temporal.rawValue),
            mechanism: .sharedInput
        )
    ])

    /// Reduces the filed readings to one per independent voice, before the arbiter counts them.
    ///
    /// Records a real outcome on every path. The common case in a chat client is `.noOp`: most
    /// turns carry no retrieved evidence, all four gates skip, and there is nothing to deflate.
    /// Saying so is the point — a stage that reports nothing when it does nothing is a stage the
    /// Diagnostics screen cannot distinguish from one that is broken.
    ///
    /// This stage cannot refuse and cannot let anything through. It changes what the arbiter is
    /// counting and never what the arbiter decides, which is why it has no `Refusal` to return.
    nonisolated func deflateSignalDependence(trace: inout PipelineTrace) async {
        let filed = trace.reservations
        guard !filed.isEmpty else {
            trace.record(.signalDependence, .skipped(reason: "no gate filed a reading to deflate"))
            return
        }

        // The readings are recorded before they are deflated, on purpose. Deflation merges two
        // judges into one voice using the declared strength, and a history of already-merged
        // voices could never be used to check whether that strength was right.
        if let turn = await PanelHistoryStore.shared.record(filed) {
            trace.notePanelTurn(id: turn)
        }

        let panel = await AbstentionSignalReducer().reduce(filed, using: Self.dependenceGraph)
        guard panel.report.isDeflated else {
            trace.record(
                .signalDependence,
                .noOp(reason: "\(panel.report.explanation); nothing to merge")
            )
            return
        }

        trace.deflateReservations(to: panel.signals)
        trace.record(.signalDependence, .ran(detail: Self.deflationDetail(panel)))
    }

    /// What the merge did, in the words the refusal downstream will need.
    ///
    /// Names the judges that merged and the mechanism, because the arbiter's refusal quotes its
    /// concurring origins by name — and a user shown "answerability and source independence each
    /// found something" after a merge deserves a trace that says which fourth judge was folded
    /// into which, rather than one that quietly lists three names where four gates ran.
    private static func deflationDetail(_ panel: DependenceReducedPanel) -> String {
        let merged = panel.report.collapsedGroups.map(\.summary).joined(separator: "; ")
        let concurring = panel.concurringVoices
        return "\(panel.report.nominalCount) gates read as "
            + "\(panel.report.independentVoices) voice(s) — \(merged); "
            + "\(concurring) concurring voice(s) reach the arbiter"
    }
}
