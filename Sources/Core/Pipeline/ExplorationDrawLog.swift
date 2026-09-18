import ExplorationChannelKit

/// Every ruling the exploration channel reached its draw on, oldest first: `true` for an
/// admission, `false` for a turn that was eligible and not drawn.
///
/// `ExplorationLedger` keeps admissions only, deliberately — it is a record of spend. That leaves
/// this app no way to ask the question every inverse-probability weight downstream depends on:
/// does the draw actually admit at `ExplorationBudget.frequency`? This log keeps exactly the
/// rulings the draw produced and nothing else. A turn outside the region, or too costly to
/// explore, never reached the draw, and counting it would test the frequency against traffic it
/// never governed.
actor ExplorationDrawLog {
    private(set) var draws: [Bool] = []

    /// Records `ruling` if the draw produced it; every other ruling is ignored.
    func record(_ ruling: AdmissionRuling) {
        switch ruling {
        case .admitted:
            draws.append(true)
        case .notDrawn:
            draws.append(false)
        case .notRefused, .outsideRegion, .tooCostly:
            break
        }
    }
}
