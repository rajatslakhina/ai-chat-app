import Foundation
import SelectionTrustKit

/// What the second axis found in one tool call's arguments.
struct SelectionTrustReading: Sendable, Equatable {
    /// Arguments whose text actually appears in a retrieved passage.
    let contentDerived: [String]
    /// Arguments the model composed, in a session that had read a passage.
    let underPoisonedFloor: [String]
    /// Whether the turn carried any retrieved passage at all.
    let floorRaised: Bool
    /// What `SelectionTrustKit` itself decided, which in this app is always inert.
    let requirement: ConfirmationRequirement

    var argumentCount: Int { contentDerived.count + underPoisonedFloor.count }

    /// True when the app's blanket `.untrusted` stamp is tainting arguments that no passage
    /// contributed to. This is the number the single field cannot express.
    var overTainting: Bool { floorRaised && contentDerived.isEmpty && !underPoisonedFloor.isEmpty }
}

/// Measures the two trust axes on a tool call's arguments.
///
/// This is deliberately not a gate. `ToolAuthorityGate` decides whether the call runs and this
/// stage never widens that decision — every tool here is read-only, and `SelectionTrustKit` holds
/// reads inert because a read's result leaves through the model and containing that is an egress
/// problem it says out loud is out of scope.
///
/// What it does instead is separate the question `ToolCallContext.forTurn` collapses. That
/// function stamps every argument `.untrusted(source:)` as soon as the turn carried one passage,
/// which is safe and coarse: with `maxProvenance: .modelAuthored` on every capability, a single
/// retrieved passage denies a calculator call whose arguments appear nowhere in it.
enum SelectionTrustGate {
    /// Substring containment against the passage text, lowercased, with short values ignored.
    ///
    /// Stated plainly because it would be easy to over-read: this is a heuristic and it is the
    /// weak half of this stage. It cannot see a value the model paraphrased out of a passage, and
    /// a short numeric argument can collide with a passage by coincidence — which is why anything
    /// under four characters is not matched at all rather than matched carelessly. It is evidence
    /// that an argument *did* come from a passage, and never proof that one did not.
    static let minimumMatchLength = 4

    static func read(
        toolName: String,
        argumentsJSON: Data,
        sources: [RetrievedSource]
    ) async -> SelectionTrustReading {
        let values = argumentValues(in: argumentsJSON)
        let corpus = sources.map { ($0.id, $0.snippet.lowercased()) }
        var parameters: [ParameterName: TaintedValue] = [:]
        var contentDerived: [String] = []
        var underFloor: [String] = []

        for (name, value) in values {
            if let sourceID = matchingSource(for: value, in: corpus) {
                parameters[ParameterName(name)] = .literal(value, .contentDerived, source: SourceID(sourceID))
                contentDerived.append(name)
            } else {
                parameters[ParameterName(name)] = .literal(value, .plannerAuthored)
                underFloor.append(name)
            }
        }

        let session = BrokerSession(
            id: SessionID(toolName),
            presenter: DecliningPresenter(),
            budget: CommitBudget(capacity: 1)
        )
        if let first = sources.first {
            await session.noteContentIngested(from: SourceID(first.id))
        }
        let result = await session.authorize(
            Invocation(intentName: toolName, effect: .read, parameters: parameters),
            key: CommitKey(toolName)
        )
        return SelectionTrustReading(
            contentDerived: contentDerived.sorted(),
            underPoisonedFloor: underFloor.sorted(),
            floorRaised: !sources.isEmpty,
            requirement: result.requirement
        )
    }

    /// The record this stage contributes, on every path.
    static func record(for reading: SelectionTrustReading, toolName: String) -> StageRecord {
        guard reading.argumentCount > 0 else {
            return StageRecord(
                stage: .selectionTrust,
                outcome: .noOp(reason: "\(toolName) was called with no arguments to attribute"),
                durationMs: 0
            )
        }
        guard reading.floorRaised else {
            return StageRecord(
                stage: .selectionTrust,
                outcome: .noOp(reason: "the turn retrieved nothing, so no floor and nothing to separate"),
                durationMs: 0
            )
        }
        return StageRecord(stage: .selectionTrust, outcome: .ran(detail: detail(for: reading)), durationMs: 0)
    }

    /// Two sentences, because a recovered separation is not a green light and the second sentence
    /// is what stops the first being read as one.
    static func detail(for reading: SelectionTrustReading) -> String {
        let counts = "\(reading.contentDerived.count) of \(reading.argumentCount) arguments "
            + "content-derived, \(reading.underPoisonedFloor.count) under a poisoned floor"
        guard reading.overTainting else {
            return counts + "; the blanket .untrusted stamp matches what the arguments actually carry"
        }
        return counts
            + "; no argument appears in any retrieved passage, so the blanket .untrusted stamp is "
            + "over-tainting this call — and substring matching cannot prove a paraphrase absent"
    }

    // MARK: - Support

    /// Top-level string and number values, which is what this app's tools take.
    static func argumentValues(in json: Data) -> [(String, String)] {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            return []
        }
        return object.keys.sorted().compactMap { key in
            switch object[key] {
            case let text as String: return (key, text)
            case let number as NSNumber: return (key, number.stringValue)
            default: return nil
            }
        }
    }

    static func matchingSource(for value: String, in corpus: [(String, String)]) -> String? {
        let needle = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard needle.count >= minimumMatchLength else { return nil }
        return corpus.first { $0.1.contains(needle) }?.0
    }
}

/// Declines, and is never asked.
///
/// This stage only ever authorizes reads, and reads are inert in `SelectionTrustKit`, so no prompt
/// is raised. It answers `false` rather than `true` so that the day this app registers a mutating
/// tool, the commit stops here instead of being waved through by a presenter nobody wrote a
/// surface for. Internal rather than private so that answer is pinned by a test instead of
/// inferred from the fact that nothing calls it.
struct DecliningPresenter: SelectionTrustKit.ConfirmationPresenter {
    func confirm(_ request: SelectionTrustKit.ConfirmationRequest) async -> Bool { false }
}
