import AgentMemoryKit
import ContextCompactionKit
import GuardrailKit
import InstructionComplianceKit
import PromptTemplateKit
import ProviderGatewayKit
import ResponseCacheKit
import RetrievalKit
import SemanticRouterKit
import Testing
@testable import AIChatApp

private let bullets = "Summarize it in 3 to 5 bullet points and don't use the word \"synergy\"."
private let contradiction = "Explain it in at most 2 sentences, across at least 3 paragraphs."

private func review(_ answer: String, users: [String]) async -> (AnswerReview, PipelineTrace) {
    let pipeline = PostModelPipeline(guardrail: GuardrailPipeline(policy: GuardrailPolicy()))
    var messages: [LLMMessage] = []
    for (index, text) in users.enumerated() {
        if index > 0 { messages.append(LLMMessage(role: .assistant, content: "Earlier answer.")) }
        messages.append(LLMMessage(role: .user, content: text))
    }
    var trace = PipelineTrace()
    let reviewed = await pipeline.review(answer: answer, sources: [], messages: messages, trace: &trace)
    return (reviewed, trace)
}

@Suite("InstructionComplianceKit - the answer checked against the request's instructions")
struct InstructionComplianceStageTests {
    @Test("broken instructions get a note under the bubble, after numberBinding, and the text is unchanged")
    func violationGetsANote() async throws {
        let answer = "- one\n- two\n- great synergy\n- four\n- five\n- six"
        let (reviewed, trace) = await review(answer, users: [bullets])
        #expect(reviewed.publishableText == answer)
        #expect(reviewed.instructionNote == "This answer doesn't follow 2 of the 3 instructions in your request: "
            + "between 3 and 5 list items (6 list items); don't use \"synergy\" (uses \"synergy\" once). "
            + "Ask for a rewrite that follows them.")
        #expect(trace.outcome(for: .instructionCompliance) == .ran(detail: "violated: 1 of 3 kept; "
            + "between 3 and 5 list items (6 list items); don't use \"synergy\" (uses \"synergy\" once)"))
        let stages = trace.records.map(\.stage)
        let compliance = try #require(stages.firstIndex(of: .instructionCompliance))
        let numbers = try #require(stages.firstIndex(of: .numberBinding))
        #expect(compliance > numbers)
    }

    @Test("an answer that keeps every instruction gets no note")
    func compliantIsQuiet() async {
        let (reviewed, trace) = await review("- one\n- two\n- three", users: [bullets])
        #expect(reviewed.instructionNote == nil)
        #expect(trace.outcome(for: .instructionCompliance) == .noOp(reason: "compliant: 3 of 3 kept"))
    }

    @Test("a preamble line is set aside, as IFEval's loose reading does")
    func preambleIsSetAside() async {
        let (reviewed, trace) = await review("Sure:\nyes, it is", users: ["Answer in lowercase."])
        #expect(reviewed.instructionNote == nil)
        #expect(trace.outcome(for: .instructionCompliance) == .noOp(reason: "compliantLoosely: 1 of 1 kept"))
    }

    @Test("a request with nothing checkable records why nothing ran")
    func nothingToCheck() async {
        let (reviewed, trace) = await review("A lock.", users: ["What is a mutex?"])
        #expect(reviewed.instructionNote == nil)
        #expect(trace.outcome(for: .instructionCompliance) == .noOp(reason: "no instructions a program can check"))
    }

    @Test("a standing instruction from an earlier turn still counts")
    func standingInstructionCarries() async {
        let (reviewed, trace) = await review(
            "A lock.", users: ["From now on, answer in lowercase.", "What is a mutex?"]
        )
        #expect(reviewed.instructionNote?.hasPrefix("This answer doesn't follow the one instruction") == true)
        #expect(trace.outcome(for: .instructionCompliance)
            == .ran(detail: "violated: 0 of 1 kept; all lowercase (has capital letters)"))
    }

    @Test("a withheld answer is not checked")
    func withheldIsSkipped() async {
        let refusal = Refusal(stage: .guardrailOutput, headline: "Withheld", explanation: "x", recovery: nil)
        let withheld = AnswerReview(
            publishableText: "", wasModified: true, groundedFraction: nil, claimCount: 0, refusal: refusal
        )
        var trace = PipelineTrace()
        let result = await PostModelPipeline.checkInstructions(
            withheld, messages: [LLMMessage(role: .user, content: bullets)], trace: &trace
        )
        #expect(result == withheld)
        #expect(trace.outcome(for: .instructionCompliance)
            == .skipped(reason: "the answer was withheld, so there is nothing to check"))
    }
}

@Suite("InstructionComplianceKit - contradictions turned back before the call")
struct InstructionConflictStageTests {
    @Test("instructions no answer can follow are refused with a way to edit the message")
    func contradictionIsRefused() async throws {
        var trace = PipelineTrace()
        let early = await PreModelPipeline.earlyRefusal(contradiction, [], &trace)
        let refusal = try #require(early)
        #expect(refusal.stage == .instructionConflict)
        #expect(refusal.headline == "Your instructions contradict each other")
        #expect(refusal.explanation == "\"at most 2 sentences\" and \"at least 3 paragraphs\" can't both hold: "
            + "at least 3 paragraphs need at least 3 sentences, more than at most 2 sentences allows. "
            + "Nothing was sent, so nothing was charged. Say which one you want.")
        #expect(refusal.recovery == .rephrase)
        #expect(refusal.recoveryTitle == "Edit your message")
        #expect(trace.outcome(for: .instructionConflict) == .refused(refusal))
        let stages = trace.records.map(\.stage)
        let tools = try #require(stages.firstIndex(of: .toolIntegrity))
        let conflict = try #require(stages.firstIndex(of: .instructionConflict))
        #expect(tools < conflict, "the catalog check runs first, as it did before this stage existed")
    }

    @Test("instructions that agree pass, and standing ones are counted as carried")
    func agreeingInstructionsPass() async {
        var trace = PipelineTrace()
        let history = [
            ConversationMessage(role: .user, text: "From now on, answer in lowercase."),
            ConversationMessage(role: .assistant, text: "ok")
        ]
        let carried = await PreModelPipeline.earlyRefusal("Use bullet points.", history, &trace)
        #expect(carried == nil)
        #expect(trace.outcome(for: .instructionConflict)
            == .ran(detail: "2 instructions, 1 carried from earlier turns, none conflict"))

        var single = PipelineTrace()
        let alone = await PreModelPipeline.earlyRefusal("Use bullet points.", [], &single)
        #expect(alone == nil)
        #expect(single.outcome(for: .instructionConflict) == .ran(detail: "1 instruction, none conflict"))

        var none = PipelineTrace()
        let plain = await PreModelPipeline.earlyRefusal("What is a mutex?", [], &none)
        #expect(plain == nil)
        #expect(none.outcome(for: .instructionConflict) == .noOp(reason: "no instructions a program can check"))
    }

    @Test("an empty conversation has no plan")
    func emptyPlan() async {
        #expect(await InstructionPlanner.plan(userTexts: []) == nil)
    }
}

@Suite("InstructionComplianceKit - the refusal on screen", .serialized)
@MainActor
struct InstructionConflictChatTests {
    private func pipeline() async -> PreModelPipeline {
        let prompts = PromptRegistry()
        _ = try? await prompts.register(name: "chat.system", template: "You are terse.")
        return PreModelPipeline(
            prompts: prompts,
            guardrail: GuardrailPipeline(policy: GuardrailPolicy()),
            router: SemanticRouter(),
            cache: ResponseCache(capacity: 8),
            memory: MemoryStore(),
            retriever: Retriever(embedder: HashingEmbeddingProvider()),
            compactor: ContextCompactor(strategies: [SlidingWindowCompactionStrategy()])
        )
    }

    @Test("a contradictory message is never sent, and Edit your message puts it back in the composer")
    func editPutsTheMessageBack() async throws {
        let harness = ExecutorHarness()
        try await harness.registerScopes()
        StubURLProtocol.setStubs([])
        let model = ChatViewModel(
            pipeline: await pipeline(),
            executor: harness.executor(),
            review: PostModelPipeline(guardrail: GuardrailPipeline(policy: GuardrailPolicy()))
        )
        let before = StubURLProtocol.requestCount
        model.draft = contradiction
        model.send()
        for _ in 0..<800 where model.isSending || model.activeRefusal == nil {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(model.activeRefusal?.stage == .instructionConflict)
        #expect(model.activeRefusal?.recoveryTitle == "Edit your message")
        #expect(StubURLProtocol.requestCount == before, "nothing may reach the provider")
        #expect(model.draft.isEmpty)

        let refusal = try #require(model.activeRefusal)
        model.recover(from: refusal)
        #expect(model.activeRefusal == nil)
        #expect(model.draft == contradiction)
    }

    @Test("the banner button resends for an ordinary recovery and asks for approval for a tool")
    func otherRecoveries() async {
        let model = ChatViewModel(
            pipeline: await pipeline(),
            executor: ExecutorHarness().executor(),
            review: PostModelPipeline(guardrail: GuardrailPipeline(policy: GuardrailPolicy()))
        )
        // No user message yet, so a resend has nothing to send, and no tool gate to ask.
        model.recover(from: Refusal(stage: .budgetReserve, headline: "x", explanation: "y", recovery: nil))
        model.recover(from: Refusal(
            stage: .toolAuthority, headline: "x", explanation: "y", recovery: .approveTool(name: "calculator")
        ))
        #expect(model.bubbles.isEmpty)
        #expect(model.isSending == false)
    }
}
