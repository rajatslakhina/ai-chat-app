import EvalHarness
import Foundation
import Testing
@testable import AIChatApp

/// The regression gate: does the assistant still behave, scored deterministically and for free.
///
/// This is the half of `EvalHarness` that does not belong in the send path. It replays committed
/// transcripts through `ReplayingModel` and scores them with `RubricScorer`, so a run costs
/// nothing, calls no provider, and cannot flake — which is the only kind of eval that survives
/// contact with a release train. The judge is deliberately absent: it is for residual subjective
/// signal, and every check here is objective.
@Suite("Eval regression gate")
struct EvalRegressionTests {
    private static let promptVersion = PromptVersion(templateID: "chat.turn", revision: 1)

    private static let descriptor = ModelDescriptor(
        identifier: "openai/gpt-4o",
        build: "2026-08",
        tier: .cloud
    )

    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private static func provenance() -> CaseProvenance {
        CaseProvenance(
            capturedAt: epoch,
            rationale: "captured from a real turn by MetadataPipeline's transcript capture"
        )
    }

    /// Answers the app has committed to. Each is a behavioural slice rather than one big pass
    /// rate, because an aggregate hides the one slice that broke.
    private static func goldenCases() throws -> [GoldenCase] {
        [
            GoldenCase(
                id: "budget-explains-microcents",
                prompt: "how is my spend tracked",
                slice: "retrieval-grounded",
                rubric: try Rubric(checks: [
                    .init(name: "names the unit", kind: .contains("microcents", caseSensitive: false)),
                    .init(name: "stays short", weight: 0.5, kind: .maxCharacters(400))
                ]),
                provenance: provenance()
            ),
            GoldenCase(
                id: "refusal-is-actionable",
                prompt: "run a tool I have not approved",
                slice: "refusal",
                rubric: try Rubric(checks: [
                    .init(name: "says what to do", kind: .contains("Approve", caseSensitive: true)),
                    // The failure this guards is real: a refusal that says only "something went
                    // wrong" is unactionable, and this app treats that as a defect.
                    .init(
                        name: "avoids the useless phrase",
                        kind: .doesNotContain("something went wrong", caseSensitive: false)
                    )
                ]),
                provenance: provenance()
            )
        ]
    }

    /// The answers as recorded. Replacing these is how a regression is noticed: the diff is the
    /// behaviour change.
    private static let recordedAnswers: [String: String] = [
        "how is my spend tracked": "Spend is settled in microcents against a monthly ceiling.",
        "run a tool I have not approved": "Approval needed — Approve calculator to let this run."
    ]

    private func record(
        prompt: String,
        caseID: String,
        text: String,
        into store: InMemoryTranscriptStore
    ) async {
        let key = TranscriptKey(
            promptVersion: Self.promptVersion,
            renderedPrompt: prompt,
            model: Self.descriptor,
            decoding: .deterministic
        )
        await store.store(
            TranscriptRecord(
                key: key,
                caseID: caseID,
                promptVersion: Self.promptVersion,
                model: Self.descriptor,
                response: ModelResponse(
                    text: text,
                    inputTokens: 12,
                    outputTokens: 14,
                    latencySeconds: 0,
                    costUSD: 0
                ),
                recordedAt: Self.epoch
            )
        )
    }

    private func store(for cases: [GoldenCase]) async -> InMemoryTranscriptStore {
        let store = InMemoryTranscriptStore()
        for goldenCase in cases {
            guard let text = Self.recordedAnswers[goldenCase.prompt] else { continue }
            await record(
                prompt: goldenCase.prompt,
                caseID: goldenCase.id,
                text: text,
                into: store
            )
        }
        return store
    }

    private func replay(
        _ goldenCase: GoldenCase,
        from store: InMemoryTranscriptStore
    ) async throws -> ModelResponse {
        let model = ReplayingModel(
            descriptor: Self.descriptor,
            store: store,
            mode: .replay,
            promptVersion: Self.promptVersion,
            caseID: goldenCase.id
        )
        return try await model.complete(prompt: goldenCase.prompt, decoding: .deterministic)
    }

    @Test("every committed answer still satisfies the rubric it was accepted under")
    func everySliceStillPasses() async throws {
        let cases = try Self.goldenCases()
        let store = await store(for: cases)
        let scorer = RubricScorer()

        for goldenCase in cases {
            let response = try await replay(goldenCase, from: store)
            let breakdown = try await scorer.score(response: response, for: goldenCase)
            #expect(
                breakdown.score.value >= 0.99,
                "\(goldenCase.slice)/\(goldenCase.id) scored \(breakdown.score.value)"
            )
        }
    }

    @Test("the gate actually fails when the behaviour changes")
    func aRegressionIsCaught() async throws {
        // A gate nobody has watched fail is a gate nobody should trust. This replays a *worse*
        // answer — the unactionable phrase the app forbids — and asserts the score drops.
        let goldenCase = try #require(try Self.goldenCases().last)
        let store = InMemoryTranscriptStore()
        await record(
            prompt: goldenCase.prompt,
            caseID: goldenCase.id,
            text: "Something went wrong.",
            into: store
        )

        let response = try await replay(goldenCase, from: store)
        let breakdown = try await RubricScorer().score(response: response, for: goldenCase)
        #expect(breakdown.score.value < 0.5, "both checks should fail on this answer")
    }

    @Test("replaying costs nothing, which is what lets this run on every pull request")
    func replayIsFree() async throws {
        let cases = try Self.goldenCases()
        let store = await store(for: cases)
        let goldenCase = try #require(cases.first)

        let response = try await replay(goldenCase, from: store)
        #expect(response.costUSD == 0)
    }
}
