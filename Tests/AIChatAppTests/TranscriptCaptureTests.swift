import EvalHarness
import Foundation
import Testing
@testable import AIChatApp

/// Turning finished turns into golden-case candidates.
///
/// The hard part of an eval suite is not scoring, it is having real cases to score. Only the app
/// sees real prompts against real answers, so only the app can produce them.
@Suite("Transcript capture")
struct TranscriptCaptureTests {
    private func pipeline(
        transcripts: (any TranscriptStore)? = InMemoryTranscriptStore()
    ) async -> MetadataPipeline {
        MetadataPipeline(
            completer: ScriptedCompleter(
                title: [MetadataHarness.goodTitle],
                followUps: [MetadataHarness.goodFollowUps]
            ),
            contracts: await Composition.makeContracts(),
            transcripts: transcripts
        )
    }

    private func generate(
        _ pipeline: MetadataPipeline,
        userText: String = "what is the capital of France",
        assistantText: String = "Paris."
    ) async -> PipelineTrace {
        var trace = PipelineTrace()
        _ = await pipeline.generate(
            userText: userText,
            assistantText: assistantText,
            trace: &trace
        )
        return trace
    }

    @Test("a finished turn is recorded, with the answer as the expected response")
    func recordsTheTurn() async throws {
        let pipeline = await pipeline()
        let trace = await generate(pipeline)

        #expect(trace.outcome(for: .transcriptCapture)?.summary.contains("recorded") == true)
        let records = await pipeline.capturedTranscripts()
        let record = try #require(records.first)
        #expect(record.response.text == "Paris.")
        #expect(record.caseID.hasPrefix("chat-"))
    }

    @Test("a transcript is recorded under deterministic decoding, or it is not reproducible")
    func decodingIsDeterministic() async throws {
        // A case recorded under sampling cannot be replayed to the same answer, and a golden case
        // that cannot be reproduced is not golden. The key encodes the decoding parameters, so
        // this is asserted through the key rather than described in a comment alone.
        let recorded = TranscriptKey(
            promptVersion: PromptVersion(templateID: "chat.turn", revision: 1),
            renderedPrompt: "what is the capital of France",
            model: ModelDescriptor(
                identifier: MetadataPipeline.defaultModelID,
                build: "live",
                tier: .cloud
            ),
            decoding: .deterministic
        )
        let pipeline = await pipeline()
        _ = await generate(pipeline)

        let records = await pipeline.capturedTranscripts()
        #expect(records.first?.key == recorded.value)
    }

    @Test("asking the same thing twice does not overwrite the recorded answer")
    func doesNotOverwrite() async throws {
        // Overwriting is how a regression quietly becomes the baseline.
        let pipeline = await pipeline()
        _ = await generate(pipeline, assistantText: "Paris.")
        let second = await generate(pipeline, assistantText: "Lyon, actually.")

        let summary = second.outcome(for: .transcriptCapture)?.summary
        #expect(summary?.contains("already recorded") == true)
        let records = await pipeline.capturedTranscripts()
        #expect(records.count == 1)
        #expect(records.first?.response.text == "Paris.")
    }

    @Test("a different question is a different case")
    func distinctPromptsAreDistinctCases() async throws {
        let pipeline = await pipeline()
        _ = await generate(pipeline, userText: "capital of France", assistantText: "Paris.")
        _ = await generate(pipeline, userText: "capital of Japan", assistantText: "Tokyo.")

        let records = await pipeline.capturedTranscripts()
        #expect(records.count == 2)
    }

    @Test("capture turned off records itself as skipped rather than vanishing")
    func captureOff() async throws {
        let pipeline = await pipeline(transcripts: nil)
        let trace = await generate(pipeline)

        #expect(trace.outcome(for: .transcriptCapture)?.summary.contains("off") == true)
        #expect(await pipeline.capturedTranscripts().isEmpty)
    }

    @Test("an empty answer is not a case, and capture never runs on one")
    func emptyAnswerIsNotACase() async throws {
        let pipeline = await pipeline()
        let trace = await generate(pipeline, assistantText: "   ")

        #expect(trace.outcome(for: .transcriptCapture) == nil)
        #expect(await pipeline.capturedTranscripts().isEmpty)
    }

    // MARK: - The suite this feeds

    @Test("captured records snapshot to the fixture the eval suite replays")
    func snapshotsForReplay() async throws {
        // This is the whole point of capturing: the store serialises to JSON that
        // `ReplayingModel` reads back, so an eval run costs nothing and cannot flake.
        let store = InMemoryTranscriptStore()
        let pipeline = await pipeline(transcripts: store)
        _ = await generate(pipeline)

        let data = try await store.snapshotData()
        #expect(!data.isEmpty)
        let reloaded = try InMemoryTranscriptStore.loaded(from: data)
        let records = await reloaded.allRecords()
        #expect(records.first?.response.text == "Paris.")
    }
}
