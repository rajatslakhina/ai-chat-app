import ArgumentAttributionKit
import Foundation

/// What the attribution ladder found in one tool call's arguments, and where it disagrees
/// with the substring rule `SelectionTrustGate` uses for the same question.
struct ArgumentAttributionReading: Sendable, Equatable {
    /// Arguments a rung located whose located keys clear the specificity floor.
    let attributed: [String]
    /// Arguments a rung located that are too cheap to be evidence of anything.
    let weak: [String]
    /// Arguments no rung reached. Not a claim that they came from elsewhere.
    let withoutEvidence: [String]
    /// One line per argument: the rung, the bits, and the source it points at.
    let findings: [String]
    /// Arguments the substring rule called content-derived that the ladder does not.
    let substringOverCounted: [String]
    /// Arguments the substring rule missed that a higher rung reaches.
    let substringUnderCounted: [String]
    let floorRaised: Bool

    var argumentCount: Int { attributed.count + weak.count + withoutEvidence.count }

    /// Upper bound on the arguments the blanket stamp taints without cause. There is no lower
    /// bound below zero and no point estimate, for the reason the package states.
    var maximumOverTaint: Int { weak.count + withoutEvidence.count }

    var disagrees: Bool { !substringOverCounted.isEmpty || !substringUnderCounted.isEmpty }
}

/// Audits the matcher the stage beside it depends on.
///
/// `SelectionTrustGate` answers "did this argument come from a passage" with case-folded
/// substring containment, skipping anything under four characters. That rule is the weak half of
/// that stage and its own doc comment says so. This stage asks the same question with a ladder —
/// verbatim, then normalised, then numeric, then token-subset — and prices whatever it locates in
/// bits, so a four-character coincidence and an eight-digit identifier stop counting the same.
///
/// It never gates. `ToolAuthorityGate` decides whether the call runs; this stage cannot widen or
/// narrow that, and every tool this app registers is read-only in any case.
///
/// **The semantic rung is deliberately not installed here.** `ArgumentAttributionKit` ships a
/// trigram scorer and does not default it on, and this app declines it for a reason of its own:
/// its tool arguments are short numeric expressions, and a character-trigram score between `2+2`
/// and a prose passage is noise. A scorer that fires on noise turns this measurement into a false
/// accusation, so the rung stays uninstalled and the reading says that it never ran.
enum ArgumentAttributionGate {
    static func read(
        toolName: String,
        argumentsJSON: Data,
        sources: [RetrievedSource]
    ) async -> ArgumentAttributionReading {
        let values = SelectionTrustGate.argumentValues(in: argumentsJSON)
        let corpus = sources.map { ($0.id, $0.snippet.lowercased()) }
        let engine = AttributionEngine(
            sources: sources.map { AttributionSource(id: $0.id, text: $0.snippet) }
        )

        var attributed: [String] = []
        var weak: [String] = []
        var withoutEvidence: [String] = []
        var findings: [String] = []
        var overCounted: [String] = []
        var underCounted: [String] = []

        for (name, value) in values {
            let outcome = await engine.attribute(ArgumentValue(name: name, rendered: value)).outcome
            let substringSaysDerived = SelectionTrustGate.matchingSource(for: value, in: corpus) != nil
            switch outcome {
            case .attributed(let evidence):
                attributed.append(name)
                findings.append(finding(name, evidence))
                if !substringSaysDerived { underCounted.append(name) }
            case .weak(let evidence, let reason):
                weak.append(name)
                findings.append("\(finding(name, evidence)) — \(reason)")
                if substringSaysDerived { overCounted.append(name) }
            case .noEvidence(let reason):
                withoutEvidence.append(name)
                findings.append("\(name): \(reason)")
                if substringSaysDerived { overCounted.append(name) }
            }
        }

        return ArgumentAttributionReading(
            attributed: attributed.sorted(),
            weak: weak.sorted(),
            withoutEvidence: withoutEvidence.sorted(),
            findings: findings.sorted(),
            substringOverCounted: overCounted.sorted(),
            substringUnderCounted: underCounted.sorted(),
            floorRaised: !sources.isEmpty
        )
    }

    /// The record this stage contributes, on every path.
    static func record(for reading: ArgumentAttributionReading, toolName: String) -> StageRecord {
        guard reading.argumentCount > 0 else {
            return StageRecord(
                stage: .argumentAttribution,
                outcome: .noOp(reason: "\(toolName) was called with no arguments to attribute"),
                durationMs: 0
            )
        }
        guard reading.floorRaised else {
            return StageRecord(
                stage: .argumentAttribution,
                outcome: .noOp(reason: "the turn retrieved nothing, so there is no passage to attribute to"),
                durationMs: 0
            )
        }
        return StageRecord(
            stage: .argumentAttribution,
            outcome: .ran(detail: detail(for: reading)),
            durationMs: 0
        )
    }

    /// Three sentences: what was found, whether it contradicts the stage beside it, and what a
    /// null result is still not allowed to mean.
    static func detail(for reading: ArgumentAttributionReading) -> String {
        let counts = "\(reading.attributed.count) of \(reading.argumentCount) arguments attributed, "
            + "at most \(reading.maximumOverTaint) over-tainted"
        let agreement = reading.disagrees
            ? "; the substring rule disagrees on \(disagreement(reading))"
            : "; the substring rule reaches the same verdict on every argument"
        return counts + agreement
            + "; the semantic rung was not installed, and finding nothing is not finding an absence"
    }

    // MARK: - Support

    private static func disagreement(_ reading: ArgumentAttributionReading) -> String {
        var parts: [String] = []
        if !reading.substringOverCounted.isEmpty {
            parts.append("\(reading.substringOverCounted.joined(separator: ", ")) (it over-counts)")
        }
        if !reading.substringUnderCounted.isEmpty {
            parts.append("\(reading.substringUnderCounted.joined(separator: ", ")) (it misses)")
        }
        return parts.joined(separator: " and ")
    }

    private static func finding(_ name: String, _ evidence: AttributionEvidence) -> String {
        let bits = String(format: "%.2f", evidence.specificityBits)
        return "\(name): \(evidence.tier) in \(evidence.span.source), \(bits) bits"
    }
}
