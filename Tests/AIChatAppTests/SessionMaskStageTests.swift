import AgentMemoryKit
import ContextCompactionKit
import GuardrailKit
import PromptTemplateKit
import ProviderGatewayKit
import ResponseCacheKit
import RetrievalKit
import SemanticRouterKit
import SessionMaskKit
import Testing
@testable import AIChatApp

/// Real package instances, the same shape as `HiddenTextStageTests`' harness: the point is that
/// GuardrailKit and SessionMaskKit compose in this order, not that a stub does.
private func sessionPipeline(masks: SessionMasks) async throws -> PreModelPipeline {
    let prompts = PromptRegistry()
    try await prompts.register(name: "chat.system", template: "You are a helpful assistant. {{locale}}")
    return PreModelPipeline(
        prompts: prompts,
        guardrail: GuardrailPipeline(policy: GuardrailPolicy()),
        router: SemanticRouter(),
        cache: ResponseCache(capacity: 4),
        memory: MemoryStore(),
        retriever: Retriever(embedder: HashingEmbeddingProvider()),
        compactor: ContextCompactor(strategies: [SlidingWindowCompactionStrategy()]),
        masks: masks
    )
}

private func prepared(
    _ pipeline: PreModelPipeline,
    _ text: String,
    history: [ConversationMessage] = [],
    conversationID: String = SessionMasks.defaultConversation
) async throws -> (PreparedTurn, PipelineTrace) {
    var trace = PipelineTrace()
    let result = await pipeline.prepare(
        userText: text,
        history: history,
        conversationID: conversationID,
        trace: &trace
    )
    guard case let .ready(turn) = result else {
        Issue.record("expected .ready, got \(result)")
        throw CancellationError()
    }
    return (turn, trace)
}

private func exchange(_ user: String, _ assistant: String) -> [ConversationMessage] {
    [ConversationMessage(role: .user, text: user), ConversationMessage(role: .assistant, text: assistant)]
}

private let typedCard = "My card is 4111 1111 1111 1111 and my email is ana@acme.io."

@Suite("SessionMaskKit - the history a later turn re-sends")
struct SessionMaskInputTests {
    @Test("a value the guardrail redacted when it was typed is masked when the history re-sends it")
    func historyNoLongerLeaks() async throws {
        let raw = await GuardrailPipeline(policy: GuardrailPolicy()).screenRequest(typedCard)
        #expect(raw.sanitizedText == "My card is [REDACTED:CREDIT_CARD] and my email is [REDACTED:EMAIL_ADDRESS].")

        let pipeline = try await sessionPipeline(masks: SessionMasks())
        let (turn, trace) = try await prepared(pipeline, "What did I give you?", history: exchange(typedCard, "Noted."))
        let sent = turn.messages.map(\.content)
        #expect(!sent.contains { $0.contains("4111 1111 1111 1111") || $0.contains("ana@acme.io") })
        #expect(sent.contains("My card is [CARD_1] and my email is [EMAIL_1]."))
        #expect(trace.outcome(for: .guardrailInput) == .noOp(reason: "no findings"), "the new message was clean")
        guard case let .ran(detail)? = trace.outcome(for: .sessionMask) else {
            Issue.record("sessionMask did not run")
            return
        }
        #expect(detail.hasPrefix("masked 2 value(s) in 1 of 4 message(s) (CARD x1, EMAIL x1)"))
    }

    @Test("older history is byte-identical turn after turn, and a re-spelled value keeps its token")
    func historyIsStable() async throws {
        let pipeline = try await sessionPipeline(masks: SessionMasks())
        let first = exchange(typedCard, "Noted.")
        let second = first + exchange("Also raj@acme.io, and ANA@ACME.IO is right.", "Got both.")
        let (turnTwo, _) = try await prepared(pipeline, "Anything else?", history: first)
        let (turnThree, _) = try await prepared(pipeline, "Summarize.", history: second)
        let two = turnTwo.messages.map(\.content)
        let three = turnThree.messages.map(\.content)
        #expect(Array(three.prefix(3)) == Array(two.prefix(3)), "system and turn 1 re-sent identically")
        #expect(three[3] == "Also [EMAIL_2], and [EMAIL_1] is right.")
    }

    @Test("two addresses stay two people")
    func distinctValuesStayDistinct() async throws {
        let pipeline = try await sessionPipeline(masks: SessionMasks())
        let history = exchange("Send it to ana@acme.io and copy raj@acme.io.", "Sent.")
        let (turn, _) = try await prepared(pipeline, "Who did you send it to?", history: history)
        #expect(turn.messages.map(\.content).contains("Send it to [EMAIL_1] and copy [EMAIL_2]."))
    }

    @Test("each conversation numbers its own values")
    func conversationsDoNotShareTokens() async throws {
        let masks = SessionMasks()
        let pipeline = try await sessionPipeline(masks: masks)
        let (inA, _) = try await prepared(pipeline, "ok", history: exchange("ana@acme.io", "Hi."), conversationID: "a")
        let (inB, _) = try await prepared(pipeline, "ok", history: exchange("raj@acme.io", "Hi."), conversationID: "b")
        #expect(inA.messages.map(\.content).contains("[EMAIL_1]"))
        #expect(inB.messages.map(\.content).contains("[EMAIL_1]"))
        #expect(await masks.existingVault(for: "a") !== masks.existingVault(for: "b"))
        #expect(await masks.existingVault(for: "c") == nil)
    }

    @Test("nothing to mask is a no-op that says how much it looked at")
    func nothingToMask() async throws {
        let pipeline = try await sessionPipeline(masks: SessionMasks())
        let (_, trace) = try await prepared(pipeline, "Plan a weekend.", history: exchange("Hi", "Hello."))
        #expect(trace.outcome(for: .sessionMask) == .noOp(reason: "nothing to mask in 4 message(s)"))
    }

    @Test("a store that cannot make a vault fails the stage visibly and sends what it sent before")
    func vaultFailureIsVisible() async throws {
        let pipeline = try await sessionPipeline(masks: SessionMasks(detectors: []))
        let (turn, trace) = try await prepared(pipeline, "Again?", history: exchange(typedCard, "Noted."))
        #expect(trace.outcome(for: .sessionMask) == .failed(message: "no vault for this conversation: noDetectors"))
        #expect(turn.messages.map(\.content).contains(typedCard))
    }

    @Test("the stage runs after compaction, on what will actually be sent")
    func runsAfterCompaction() async throws {
        let pipeline = try await sessionPipeline(masks: SessionMasks())
        let (_, trace) = try await prepared(pipeline, "Hello")
        let stages = trace.records.map(\.stage)
        let compaction = try #require(stages.firstIndex(of: .contextCompaction))
        #expect(stages.firstIndex(of: .sessionMask) == compaction + 1)
    }

    @Test("every role has a source, so the vault can say where a value came from")
    func sourcesByRole() {
        let names = [LLMMessageRole.system, .user, .assistant, .tool].map { PreModelPipeline.maskSource(for: $0).name }
        #expect(names == ["system", "user", "assistant", "tool:result"])
    }

    @Test("the vault reads GuardrailKit's own detectors, category for category")
    func guardrailDetectorsAdapted() {
        let categories = GuardrailSpanDetector.guardrailDefaults.map(\.category)
        #expect(categories == [.email, .phone, .card, .ssn])
        let email = GuardrailSpanDetector(detector: EmailAddressDetector())
        #expect(email.canonicalKey(for: "Ana@Acme.IO") == "ana@acme.io")
        let card = GuardrailSpanDetector(detector: CreditCardDetector())
        #expect(card.canonicalKey(for: "4111-1111 1111-1111") == "4111111111111111")
        #expect(card.spans(in: typedCard).map(\.value) == ["4111 1111 1111 1111"])
    }
}

@Suite("SessionMaskKit - the answer, before the output guardrail")
struct SessionMaskOutputTests {
    private func review(
        _ answer: String,
        masks: SessionMasks,
        conversationID: String = SessionMasks.defaultConversation
    ) async -> (AnswerReview, PipelineTrace) {
        let pipeline = PostModelPipeline(guardrail: GuardrailPipeline(policy: GuardrailPolicy()), masks: masks)
        var trace = PipelineTrace()
        let reviewed = await pipeline.review(answer: answer, sources: [], conversationID: conversationID, trace: &trace)
        return (reviewed, trace)
    }

    private func seeded() async throws -> SessionMasks {
        let masks = SessionMasks()
        _ = try await prepared(
            try await sessionPipeline(masks: masks),
            "ok",
            history: exchange("ana@acme.io and raj@acme.io", "Hi.")
        )
        return masks
    }

    @Test("a restored value is screened by the output guardrail exactly as before")
    func restoredThenScreened() async throws {
        let (reviewed, trace) = await review("I will write to [EMAIL_1].", masks: try await seeded())
        #expect(reviewed.publishableText == "I will write to [REDACTED:EMAIL_ADDRESS].")
        #expect(reviewed.wasModified)
        #expect(trace.outcome(for: .sessionRestore) == .ran(detail: "restored 1 token(s) for the output guardrail to screen"))
        let stages = trace.records.map(\.stage)
        let restore = try #require(stages.firstIndex(of: .sessionRestore))
        #expect(stages[restore - 1] == .hiddenTextOutput)
        #expect(stages[restore + 1] == .guardrailOutput)
    }

    @Test("invented and respelled tokens are named and left as written")
    func neverGuesses() async throws {
        let (reviewed, trace) = await review("Sent to [EMAIL_9], cc email_2.", masks: try await seeded())
        #expect(reviewed.publishableText == "Sent to [EMAIL_9], cc email_2.")
        #expect(
            trace.outcome(for: .sessionRestore) == .ran(
                detail: "restored 0 token(s) for the output guardrail to screen; "
                    + "never minted, left as written: [EMAIL_9]; respelled, left as written: email_2"
            )
        )
    }

    @Test("a conversation that never masked anything has nothing to restore")
    func noVault() async {
        let (reviewed, trace) = await review("Sent to [EMAIL_1].", masks: SessionMasks(), conversationID: "fresh")
        #expect(reviewed.publishableText == "Sent to [EMAIL_1].")
        #expect(trace.outcome(for: .sessionRestore) == .noOp(reason: "nothing was masked in this conversation"))
    }

    @Test("an answer without tokens passes through")
    func noTokens() async throws {
        let (reviewed, trace) = await review("Lisbon is lovely in May.", masks: try await seeded())
        #expect(reviewed.publishableText == "Lisbon is lovely in May.")
        #expect(!reviewed.wasModified)
        #expect(trace.outcome(for: .sessionRestore) == .noOp(reason: "no session tokens in the answer"))
    }
}
