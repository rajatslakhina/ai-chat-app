import GuardrailKit
import StreamReleaseKit
import Testing
@testable import AIChatApp

@Suite("LiveStreamRelease")
struct LiveStreamReleaseTests {
    private struct Broken: Error {}

    private static let sample =
        "Mail jane.doe@example.com or call (555) 123-4567; card 4111 1111 1111 1111, SSN 123-45-6789."

    @Test("the stage belongs to StreamReleaseKit")
    func catalog() {
        #expect(PipelineStage.streamRelease.package == "StreamReleaseKit")
        #expect(PipelineStage.streamRelease.title == "Live stream release")
    }

    @Test("what streams is what the output guardrail publishes")
    func matchesGuardrailKit() async throws {
        let scanners = try #require(LiveStreamRelease.scanners())
        let streamed = await ReleaseGate.reference(for: Self.sample, scanners: scanners)
        let reviewed = await GuardrailPipeline(policy: GuardrailPolicy()).screenResponse(Self.sample)
        #expect(streamed == reviewed.sanitizedText)
        #expect(!streamed.contains("jane"))
    }

    @Test("every two-way split of the stream shows the same text")
    func chunkInvariant() async throws {
        let scanners = try #require(LiveStreamRelease.scanners())
        let reference = await ReleaseGate.reference(for: Self.sample, scanners: scanners)
        let scalars = Array(Self.sample.unicodeScalars)
        for cut in 0...scalars.count {
            let gate = ReleaseGate(scanners: scanners)
            var shown = await gate.ingest(String(String.UnicodeScalarView(scalars[..<cut]))).text
            shown += await gate.ingest(String(String.UnicodeScalarView(scalars[cut...]))).text
            shown += await gate.finish().text
            #expect(shown == reference, "cut at \(cut)")
        }
    }

    @Test("scanners that fail to build stream unscreened, and the trace says so")
    func brokenScanners() {
        #expect(LiveStreamRelease.scanners(building: { throw Broken() }) == nil)
        #expect(LiveStreamRelease.outcome(nil) == LiveStreamRelease.unscreened)
        #expect(LiveStreamRelease.unscreened.isFailure)
    }

    @Test("a redaction runs the stage; a clean stream is a no-op; both report the lag")
    func outcomes() {
        var stats = ReleaseStats()
        stats.peakWithheld = 42
        #expect(LiveStreamRelease.outcome(stats).summary.contains("no PII"))
        #expect(LiveStreamRelease.outcome(stats).summary.contains("42 character"))
        stats.redactions = 2
        #expect(LiveStreamRelease.outcome(stats) == .ran(
            detail: "kept 2 PII span(s) off the live stream; the bubble trailed the stream by up to 42 character(s)"
        ))
    }
}
