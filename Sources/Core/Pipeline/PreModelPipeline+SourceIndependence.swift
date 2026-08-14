import Foundation
import SourceIndependenceKit

/// What the independence pass established, and whether the turn may continue.
enum SourceIndependenceOutcome: Sendable, Equatable {
    /// Provenance was established. The report carries the document keys the stability pass needs.
    case established(IndependenceReport)
    /// There was nothing to establish — no passages, or only one.
    case notApplicable
    /// Do not send this turn.
    case refused(Refusal)
}

extension PreModelPipeline {
    /// Works out how many independent sources are actually behind the retrieved passages, and
    /// hands the answer to the stability pass below it.
    ///
    /// This stage exists because of a note the previous run left in
    /// ``PreModelPipeline/references(for:)``: `RetrievedSource` carries no document identifier, so
    /// that function used `title` and wrote down what it cost. This does not fully fix that — the
    /// retrieval layer still returns no URL, so the locator half of `SourceIndependenceKit` has
    /// nothing to work with here and the honest thing is to say so rather than dress it up.
    ///
    /// What it does add is a **second** signal on top of the title. `title` merges chunks that
    /// declare the same title and nothing else. Two chunks that are substantially the same text
    /// under two different titles — the same passage indexed twice, a document and its copy — look
    /// like two independent sources to every stage in this app, and to the "2 sources" chip the
    /// user sees. Shingle containment catches those. It can only ever merge *more* than the title
    /// alone did, which is the direction this app already chose: under-reporting independence
    /// routes a sound answer to review and costs a moment, over-reporting lets one source read
    /// twice pass as corroboration and costs trust.
    ///
    /// Runs after the answerability gate admits and before stability is measured. Measuring
    /// provenance for a turn the app already refused would be work nobody reads.
    /// `nonisolated` because it reads nothing but an immutable, `Sendable` analyzer and pure
    /// statics. Isolating a pure function would force `inout` state across an actor boundary for
    /// no benefit, and the trace has to be `inout` — a refusal with no record of the stages before
    /// it is what the Diagnostics screen exists to prevent.
    nonisolated func establishSourceIndependence(
        of sources: [RetrievedSource],
        trace: inout PipelineTrace
    ) -> SourceIndependenceOutcome {
        guard sources.count > 1 else {
            trace.record(
                .sourceIndependence,
                .skipped(reason: "\(sources.count) passage(s); independence is a question about several")
            )
            return .notApplicable
        }

        let report = independence.analyse(sources.map(Self.passage))
        let byText = Self.redundancyMergedSources(in: report)

        guard !byText.isEmpty else {
            trace.record(
                .sourceIndependence,
                .noOp(reason: "\(report.establishedSourceCount) source(s) across \(sources.count) "
                    + "passage(s); the titles already said everything the text could")
            )
            return .established(report)
        }

        if let refusal = Self.refusalForCollapsedCorroboration(report, sources: sources, merged: byText) {
            trace.record(.sourceIndependence, .refused(refusal))
            return .refused(refusal)
        }

        trace.record(
            .sourceIndependence,
            .ran(detail: "\(report.establishedSourceCount) source(s) across \(sources.count) passage(s); "
                + "text matching merged \(byText.map(\.summary).joined(separator: " | "))")
        )
        return .established(report)
    }

    /// The one refusal this stage makes.
    ///
    /// Not "there is only one source" — answering from one document is ordinary, and this app has
    /// already refused three legitimate questions by treating thin evidence as grounds to stop.
    /// The narrow case here is different in kind: every passage collapsed into a **single** source,
    /// and it took *text matching* to see it, which means the titles differ. The user is looking at
    /// a chip that says several sources, the titles under it are different, and they are the same
    /// writing. That is not thin evidence — it is the app telling the user something untrue about
    /// where its answer came from, and the honest move is to stop rather than to footnote it.
    static func refusalForCollapsedCorroboration(
        _ report: IndependenceReport,
        sources: [RetrievedSource],
        merged: [IndependentSource]
    ) -> Refusal? {
        guard report.establishedSourceCount == 1, report.unattributed.isEmpty else { return nil }
        let titles = Set(sources.map(\.title))
        guard titles.count > 1 else { return nil }
        return Refusal(
            stage: .sourceIndependence,
            headline: "These sources are the same text",
            explanation: "\(sources.count) passages were retrieved under \(titles.count) different "
                + "titles, and they are substantially the same writing — \(merged.count) of them "
                + "matched on content. Answering would present one source as though several agreed.",
            recovery: .shortenConversation
        )
    }

    /// The sources that text matching merged, as opposed to the ones the title already merged.
    ///
    /// Only `textualRedundancy` counts. A `declaredDocument` merge is the title agreeing with
    /// itself, which this app could already see and which tells the user nothing new.
    static func redundancyMergedSources(in report: IndependenceReport) -> [IndependentSource] {
        report.sources.filter { source in
            source.mergeReasons.contains { reason in
                if case .textualRedundancy = reason { return true }
                return false
            }
        }
    }

    /// A retrieved passage, with the best provenance this app can honestly supply.
    ///
    /// `documentID` is the title, which preserves exactly what ``references(for:independence:)``
    /// did before this stage existed. No `locator`: the retrieval layer produces no URL, and
    /// passing the title as one would put the same signal through the canonicaliser twice and
    /// invent a second opinion out of it.
    static func passage(for source: RetrievedSource) -> SourceIndependenceKit.Passage {
        SourceIndependenceKit.Passage(id: source.id, documentID: source.title, text: source.snippet)
    }
}

extension PreModelPipeline {
    /// ``establishSourceIndependence(of:trace:)`` flattened for the caller, which wants two
    /// questions answered and does not care about the shape of the enum in between.
    ///
    /// Lives here rather than in the pipeline body so the actor stays under its length limit by
    /// holding orchestration rather than stage logic.
    nonisolated func resolveIndependence(
        of sources: [RetrievedSource],
        trace: inout PipelineTrace
    ) -> (report: IndependenceReport?, refusal: Refusal?) {
        switch establishSourceIndependence(of: sources, trace: &trace) {
        case let .established(report):
            return (report, nil)
        case .notApplicable:
            return (nil, nil)
        case let .refused(refusal):
            return (nil, refusal)
        }
    }
}
