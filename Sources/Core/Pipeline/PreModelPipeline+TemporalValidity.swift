import AnswerabilityKit
import Foundation
import TemporalValidityAnswerability
import TemporalValidityKit

extension PreModelPipeline {
    /// Asks whether the gate's admission rests on passages that are still entitled to speak.
    ///
    /// Every gate before this one judges *content*: does the evidence cover the question, do the
    /// passages disagree, how many distinct voices are behind them, would the ruling survive losing
    /// one. Not one of them knows what time it is, so passages from a snapshot taken in 2023 count
    /// exactly as much as one written this morning and the arithmetic is working as designed.
    ///
    /// Runs immediately after the answerability gate admits, and before independence and stability,
    /// because it needs nothing from either — no document keys, no merge report, just the dates the
    /// corpus already carried. It costs no model call.
    ///
    /// `nonisolated` for the reason ``establishSourceIndependence(of:trace:)`` is: it reads an
    /// immutable `Sendable` analyzer and pure statics, and `trace` has to cross as `inout`, which
    /// exclusive access will not let through an actor boundary.
    nonisolated func establishTemporalValidity(
        question: String,
        sources: [RetrievedSource],
        trace: inout PipelineTrace
    ) -> Refusal? {
        guard !sources.isEmpty else {
            trace.record(.temporalValidity, .skipped(reason: "no passages to date"))
            return nil
        }

        guard sources.contains(where: { $0.observedAt != nil && $0.subject != nil }) else {
            // The honest outcome for a corpus this app does not own. Recorded as `noOp` rather
            // than `ran` so the Diagnostics screen does not show a temporal check that checked
            // nothing.
            trace.record(
                .temporalValidity,
                .noOp(reason: "\(sources.count) passage(s), none carrying both a subject and a date")
            )
            return nil
        }

        let assessment = Self.temporalAnalyzer.assess(sources.map(Self.observation), asOf: Date())
        let finding = TemporalAdmissionProbe().probe(
            Question(question),
            evidence: sources.map { EvidenceItem(id: $0.id, text: $0.snippet) },
            assessment: assessment
        )

        switch finding {
        case .timeDependent(_, _, let withheld):
            let refusal = Self.refusalForStaleAdmission(withheld: withheld, sources: sources)
            trace.record(.temporalValidity, .refused(refusal))
            return refusal

        case .timeInvariant(let verdict):
            trace.record(
                .temporalValidity,
                .ran(detail: "\(assessment.entitledFloor) of \(sources.count) passage(s) entitled; "
                    + "\(verdict) either way")
            )
            return nil

        case .undetermined(let reason):
            trace.record(.temporalValidity, .noOp(reason: reason))
            return nil
        }
    }

    /// The one refusal this stage makes.
    ///
    /// Narrow on purpose, and the narrowness is learned. Three runs in a row wired a wholesale
    /// refusal into these gates and all three were wrong; the fix each time was to refuse only on
    /// the case that is different *in kind* rather than merely worse. Stale evidence being present
    /// is ordinary — most of this corpus is a snapshot. What is not ordinary is the gate's *answer*
    /// depending on it: withhold the passages that have run out and the question stops being
    /// answerable. The app was about to answer on the strength of a document that has expired, and
    /// the user would have no way to tell.
    static func refusalForStaleAdmission(withheld: [String], sources: [RetrievedSource]) -> Refusal {
        let titles = Set(sources.filter { withheld.contains($0.id) }.map(\.title))
            .sorted()
            .joined(separator: ", ")
        return Refusal(
            stage: .temporalValidity,
            headline: "This answer would rest on out-of-date sources",
            explanation: "\(withheld.count) of the \(sources.count) passages retrieved have been "
                + "superseded or have passed their review window (\(titles)). Without them there "
                + "is not enough current evidence to answer, so answering would present a stale "
                + "snapshot as though it were today's position.",
            recovery: .shortenConversation
        )
    }

    /// The analyzer, built from the corpus's own declarations.
    ///
    /// `fallback` is deliberately absent. A default window would give every passage from an
    /// unknown corpus an expiry date nobody chose, and this stage would start refusing turns on
    /// the strength of a number invented here.
    static var temporalAnalyzer: TemporalValidityAnalyzer {
        var catalog: [SubjectKey: ClaimVolatility] = [:]
        for declaration in AppKnowledge.volatility.values {
            guard let window = declaration.window else {
                catalog[SubjectKey(declaration.subject)] = .immutable
                continue
            }
            catalog[SubjectKey(declaration.subject)] = ClaimVolatility(validityWindow: window)
        }
        return TemporalValidityAnalyzer(catalog: VolatilityCatalog(catalog))
    }

    /// A retrieved passage in the shape the analyzer reads.
    ///
    /// A passage with no subject gets its own, keyed on its id: it can then be dated, but it can
    /// never supersede or be superseded by anything else, which is the correct answer when nobody
    /// said what it is a reading of.
    static func observation(for source: RetrievedSource) -> EvidenceObservation {
        EvidenceObservation(
            id: source.id,
            subject: SubjectKey(source.subject ?? "unattributed:\(source.id)"),
            observedAt: source.observedAt
        )
    }
}
