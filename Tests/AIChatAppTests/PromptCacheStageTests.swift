import EvalHarness
import Foundation
import PromptCacheKit
import ProviderGatewayKit
import Testing
@testable import AIChatApp

// MARK: - Fixtures

/// Conversations built to a known size, so every token count in an assertion can be worked out by
/// hand rather than read back from the code under test.
private enum Layout {
    /// 4,400 characters, which the app's own characters/4 estimate makes exactly 1,100 tokens: enough
    /// that the earlier prompt of any pair clears the 1,024-token minimum by itself.
    static func instructions(_ marker: String = "s") -> String {
        marker + String(repeating: "s", count: 4_399)
    }

    /// Ten estimated tokens.
    static func line(_ marker: String) -> String {
        marker + String(repeating: "x", count: 39)
    }

    static func message(_ role: LLMMessageRole, _ text: String) -> SentPrompt.Message {
        SentPrompt.Message(role: role, content: text)
    }

    static func usage(prompt: Int, cached: Int = 0, model: String = "openai/gpt-4o") -> OpenRouterUsage {
        OpenRouterUsage(
            requestID: nil,
            model: model,
            promptTokens: prompt,
            completionTokens: 5,
            cachedPromptTokens: cached,
            reportedCostUSD: nil
        )
    }

    static func estimated(_ messages: [SentPrompt.Message]) -> Int {
        messages.reduce(0) { $0 + $1.estimatedTokens }
    }

    static func request(
        _ messages: [SentPrompt.Message],
        model: String = "openai/gpt-4o",
        cached: Int = 0,
        promptTokens: Int? = nil,
        at seconds: TimeInterval = 0
    ) -> SentPrompt {
        SentPrompt(
            modelID: model,
            messages: messages,
            usage: usage(prompt: promptTokens ?? estimated(messages), cached: cached, model: model),
            sentAt: Date(timeIntervalSince1970: 1_000 + seconds)
        )
    }

    /// Request `index` of a conversation that grows by one exchange per request: the system
    /// message, every earlier question and answer, then this request's own question.
    static func messages(at index: Int, system: String = instructions()) -> [SentPrompt.Message] {
        var result = [message(.system, system)]
        for earlier in 0..<index {
            result.append(message(.user, line("q\(earlier)")))
            result.append(message(.assistant, line("a\(earlier)")))
        }
        result.append(message(.user, line("q\(index)")))
        return result
    }

    /// `count` requests, `spacing` seconds apart, each carrying the cached tokens `cached` names
    /// for it. Request `n` is 1,110 + 20n estimated tokens.
    static func conversation(
        count: Int,
        spacing: TimeInterval = 30,
        model: String = "openai/gpt-4o",
        cached: (Int) -> Int = { _ in 0 }
    ) -> [SentPrompt] {
        (0..<count).map { index in
            request(
                messages(at: index),
                model: model,
                cached: cached(index),
                at: Double(index) * spacing
            )
        }
    }
}

// MARK: - The stage

@Suite("Prompt cache stage")
struct PromptCacheStageTests {
    private func outcome(_ prompts: [SentPrompt]) -> StageOutcome {
        MetadataPipeline.promptCacheOutcome(prompts)
    }

    private func detail(_ prompts: [SentPrompt]) -> String {
        if case let .ran(text) = outcome(prompts) { return text }
        Issue.record("expected .ran, got \(outcome(prompts))")
        return ""
    }

    // MARK: the paths that do nothing, and say why

    @Test("no recorded request is skipped, and the reason names what ends a turn without one")
    func nothingSent() {
        guard case let .skipped(reason) = outcome([]) else {
            Issue.record("expected skipped")
            return
        }
        #expect(reason.contains("no request this conversation sent has a provider-reported usage"))
        #expect(reason.contains("a cache hit, a refusal and a replayed result"))
    }

    @Test("one request has nothing to be compared with")
    func oneRequest() {
        guard case let .noOp(reason) = outcome(Layout.conversation(count: 1)) else {
            Issue.record("expected noOp")
            return
        }
        #expect(reason.contains("only one request to openai/gpt-4o is on record"))
        #expect(reason.contains("this session, so there is no second prompt to compare its prefix with"))
    }

    @Test("a model switch leaves one comparable request, because a cache belongs to one model")
    func modelSwitch() {
        let prompts = Layout.conversation(count: 2, model: "a/one") + Layout.conversation(count: 1, model: "b/two")
        guard case let .noOp(reason) = outcome(prompts) else {
            Issue.record("expected noOp")
            return
        }
        #expect(reason.contains("only one request to b/two is on record"))
        #expect(reason.contains("since the model last changed, and a provider's cache belongs to one model"))
    }

    @Test("prompts under the cacheable minimum are a no-op, and the numbers are in the reason")
    func belowMinimum() {
        let prompts = (0..<3).map { index in
            Layout.request(Layout.messages(at: index, system: "You are terse."), at: Double(index))
        }
        guard case let .noOp(reason) = outcome(prompts) else {
            Issue.record("expected noOp")
            return
        }
        #expect(reason.contains("among 3 requests is about"))
        #expect(reason.contains("under the 1024 a provider starts caching at"))
        #expect(reason.contains("no layout could have produced a cache read yet"))
    }

    @Test("only the earlier prompts count towards the minimum: the newest can be as large as it likes")
    func newestPromptDoesNotCount() {
        let small = Layout.messages(at: 0, system: "You are terse.")
        let huge = small + [Layout.message(.assistant, Layout.instructions("h"))]
        guard case .noOp = outcome([Layout.request(small), Layout.request(huge)]) else {
            Issue.record("a cache can only read as much as the earlier prompt held")
            return
        }
    }

    // MARK: the layout

    @Test("a conversation that only ever appends keeps a stable prefix")
    func stableGrowth() {
        let text = detail(Layout.conversation(count: 3))
        #expect(text.contains("3 requests to openai/gpt-4o audited, the largest earlier prompt about 1130 tokens"))
        #expect(text.contains("2 of 2 transition(s) left every cacheable token of the previous prompt matchable"))
        #expect(text.contains("on average 100.0% of the previous prompt's tokens stayed matchable"))
        #expect(text.contains("every change was an append behind an unchanged prefix"))
        #expect(!text.contains("the prefix first broke"))
    }

    @Test("a system message rebuilt every turn is reported as a frozen block that keeps changing")
    func rebuiltSystemMessage() {
        let prompts = (0..<3).map { index in
            Layout.request(Layout.messages(at: index, system: Layout.instructions("\(index)")), at: Double(index))
        }
        let text = detail(prompts)
        #expect(text.contains("0 of 2 transition(s) left every cacheable token"))
        #expect(text.contains("on average 0.0% of the previous prompt's tokens stayed matchable"))
        #expect(text.contains(
            "the prefix first broke on request 2: system message changed, leaving 0 tokens matchable "
                + "and invalidating 1100; it broke on 2 of 2 transition(s)"
        ))
        #expect(text.contains("system message, declared frozen, changed on 2 of 2"))
        #expect(text.contains("remembered facts and retrieved excerpts"))
    }

    @Test("an edited earlier message names the message, the tokens it kept, and its declared volatility")
    func editedHistory() {
        let first = Layout.request(Layout.messages(at: 0), at: 0)
        let second = Layout.request(Layout.messages(at: 1), at: 30)
        var edited = Layout.messages(at: 2)
        edited[2] = Layout.message(.assistant, Layout.line("EDITED"))
        let text = detail([first, second, Layout.request(edited, at: 60)])

        #expect(text.contains("1 of 2 transition(s) left every cacheable token"))
        #expect(text.contains("the prefix first broke on request 3: message 2 changed"))
        // The system message and the first question survive; the answer after them is what was
        // edited, so 1,100 + 10 tokens stay matchable and the 10-token answer is lost.
        #expect(text.contains("leaving 1110 tokens matchable and invalidating 10"))
        #expect(text.contains("it broke on 1 of 2 transition(s), and message 2, declared turn, changed on 1 of 2"))
        #expect(!text.contains("remembered facts"), "only the system message is explained that way")
    }

    @Test("a conversation cut short is reported as dropped messages, with no churn to blame")
    func truncatedConversation() {
        let text = detail([
            Layout.request(Layout.messages(at: 1), at: 0),
            Layout.request(Array(Layout.messages(at: 1).prefix(2)), at: 30)
        ])
        #expect(text.contains("the prefix first broke on request 2: message 2 was dropped"))
        #expect(text.contains("it broke on 1 of 1 transition(s); "), "the verdict line ends there")
        #expect(!text.contains(", and message"), "a dropped message is not a segment that changed")
    }

    @Test("every kind of break has a sentence, including the ones this app's layout rarely produces")
    func breakText() {
        let read = MetadataPipeline.promptCacheBreakText
        #expect(read(.identical) == "the previous prompt was kept whole")
        #expect(read(.appendOnly) == "the previous prompt was kept whole")
        #expect(read(.mutated(id: "message 4", declared: .turn)) == "message 4 changed")
        #expect(read(.reordered(id: "message 4")) == "message 4 moved")
        #expect(read(.inserted(id: "message 4")) == "message 4 appeared")
        #expect(read(.removed(id: "message 4")) == "message 4 was dropped")
    }

    @Test("the scope line states the preset, the lifetime, and what is not counted")
    func scope() {
        let text = detail(Layout.conversation(count: 2))
        #expect(text.contains("automatic-caching preset (1024-token minimum, 600s lifetime)"))
        #expect(text.contains("the app sets no cache markers"))
        #expect(text.contains("tool definitions and other conversations' requests are not counted"))
    }

    // MARK: reconciling with what the provider reported

    @Test("a provider whose cached count matches the layout agrees with it")
    func providerAgrees() {
        // Request n's prompt is 1,110 + 20n tokens, so the earlier prompt a cache could read is the
        // previous request's whole size: 1,110 and then 1,130.
        let text = detail(Layout.conversation(count: 3) { [0, 1_110, 1_130][$0] })
        #expect(text.contains(
            "against the provider's own cached-token counts on 2 transition(s), 2 agreed with the layout, "
                + "0 cached less, 0 cached more, and 0 reported none"
        ))
    }

    @Test("a provider that cached noticeably less than the layout allowed is counted as reading less")
    func providerReadLess() {
        let text = detail(Layout.conversation(count: 3) { [0, 610, 1_130][$0] })
        #expect(text.contains("1 agreed with the layout, 1 cached less, 0 cached more"))
    }

    @Test("a cached count inside the block tolerance is agreement, not noise")
    func withinTolerance() {
        let text = detail(Layout.conversation(count: 2) { [0, 1_110 - 128][$0] })
        #expect(text.contains("on 1 transition(s), 1 agreed with the layout"))
    }

    @Test("a provider that cached more than the layout allowed is counted, and a lapse explains the gap")
    func providerReadMore() {
        // 700s apart is past the 600s lifetime, so the layout predicts nothing was still cached.
        // Request 1 reports 600 cached anyway; request 2 reports none, which the lapse predicted.
        let text = detail(Layout.conversation(count: 3, spacing: 700) { [0, 600, 0][$0] })
        #expect(text.contains("1 agreed with the layout, 0 cached less, 1 cached more"))
    }

    @Test("a zero where the layout allowed a hit is its own count, not the provider reading less")
    func silentProvider() {
        let text = detail(Layout.conversation(count: 3))
        #expect(text.contains("0 agreed with the layout, 0 cached less, 0 cached more, and 2 reported none"))
        #expect(text.contains("which a provider that does not cache, or omits the count, also produces"))
    }

    @Test("a request with no reported prompt size cannot be scaled, so nothing is compared")
    func noReportedSize() {
        let prompts = Layout.conversation(count: 3).map {
            SentPrompt(modelID: $0.modelID, messages: $0.messages, usage: Layout.usage(prompt: 0), sentAt: $0.sentAt)
        }
        let text = detail(prompts)
        #expect(text.contains("no request carried a provider-reported prompt size"))
        #expect(!text.contains("against the provider's own cached-token counts"))
    }

    @Test("the predicted read is scaled to the provider's own units, and zeroed below the minimum or after a lapse")
    func predictedRead() {
        let policy = MetadataPipeline.promptCachePolicy
        func predict(_ retained: Int, gap: TimeInterval = 30) -> Int {
            MetadataPipeline.promptCachePredictedRead(
                retained: retained,
                estimatedTotal: 1_000,
                providerTotal: 1_500,
                gap: gap,
                policy: policy
            )
        }
        #expect(predict(800) == 1_200, "800 of 1,000 estimated tokens is 1,200 of the provider's 1,500")
        #expect(predict(500) == 0, "750 provider tokens is under the 1,024 minimum")
        #expect(predict(800, gap: 600) == 1_200, "a gap of exactly the lifetime has not lapsed")
        #expect(predict(800, gap: 601) == 0, "past the lifetime the earlier entry is gone")
        #expect(
            MetadataPipeline.promptCachePredictedRead(
                retained: 0, estimatedTotal: 0, providerTotal: 0, gap: 0, policy: policy
            ) == 0,
            "an empty prompt must not divide by zero"
        )
    }

    // MARK: which requests are audited

    @Test("the audited run is the trailing requests to the latest model, at most one window long")
    func run() {
        let many = Layout.conversation(count: SentPrompt.window + 3)
        #expect(MetadataPipeline.promptCacheRun(many, model: "openai/gpt-4o").count == SentPrompt.window)
        #expect(
            MetadataPipeline.promptCacheRun(many, model: "openai/gpt-4o").last?.sentAt == many.last?.sentAt,
            "the window keeps the newest requests"
        )

        let mixed = Layout.conversation(count: 3, model: "a/one") + Layout.conversation(count: 2, model: "b/two")
        #expect(MetadataPipeline.promptCacheRun(mixed, model: "b/two").count == 2)
        #expect(MetadataPipeline.promptCacheRun(mixed, model: "a/one").isEmpty)
    }

    @Test("the layout is audited as sent: a prompt the package would reorder is not tidied first")
    func layoutIsNotCanonicalised() {
        let layout = MetadataPipeline.promptCacheAssemble(
            Layout.request(Layout.messages(at: 1))
        )
        #expect(layout.segments.map(\.id) == ["system message", "message 1", "message 2", "message 3"])
        #expect(layout.segments.map(\.volatility) == [.frozen, .turn, .turn, .ephemeral])
        #expect(layout.totalTokens == 1_130)
        #expect(layout.segments[1].content.hasPrefix("user: "), "the role is part of what a prefix matches on")
    }

    @Test("a request with no system message starts with turns, and a lone user message is ephemeral")
    func withoutSystemMessage() {
        let noSystem = MetadataPipeline.promptCacheAssemble(
            Layout.request([Layout.message(.user, "hi"), Layout.message(.assistant, "hello")])
        )
        #expect(noSystem.segments.map(\.volatility) == [.turn, .turn])
        let lone = MetadataPipeline.promptCacheAssemble(Layout.request([Layout.message(.user, "hi")]))
        #expect(lone.segments.map(\.volatility) == [.ephemeral])
    }

    // MARK: the contract every stage in this pipeline keeps

    @Test("no path of this stage produces a refusal")
    func neverRefuses() {
        let paths: [[SentPrompt]] = [
            [],
            Layout.conversation(count: 1),
            Layout.conversation(count: 3),
            (0..<3).map { Layout.request(Layout.messages(at: $0, system: Layout.instructions("\($0)")), at: Double($0)) }
        ]
        for prompts in paths {
            #expect(!outcome(prompts).isRefusal)
            #expect(!outcome(prompts).isFailure, "nothing this stage constructs can throw")
        }
    }
}

// MARK: - On the trace

@Suite("Prompt cache stage on the trace")
struct PromptCacheTraceTests {
    private func pipeline() async -> MetadataPipeline {
        MetadataPipeline(
            completer: ScriptedCompleter(
                title: [MetadataHarness.goodTitle],
                followUps: [MetadataHarness.goodFollowUps]
            ),
            contracts: await Composition.makeContracts(),
            transcripts: InMemoryTranscriptStore()
        )
    }

    @Test("the audit records exactly one promptCache entry, with the outcome the prompts earn")
    func recordsOnce() async {
        var trace = PipelineTrace()
        await pipeline().auditPromptCache(trace: &trace, prompts: Layout.conversation(count: 3))
        #expect(trace.records.filter { $0.stage == .promptCache }.count == 1)
        guard case let .ran(detail) = trace.outcome(for: .promptCache) else {
            Issue.record("expected ran")
            return
        }
        #expect(detail.contains("3 requests to openai/gpt-4o audited"))
        #expect(trace.refusal == nil)
    }

    @Test("a generation with no request history records an honest skip rather than guessing")
    func generateWithoutHistory() async {
        var trace = PipelineTrace()
        _ = await pipeline().generate(userText: "hi", assistantText: "hello", trace: &trace)
        guard case let .skipped(reason) = trace.outcome(for: .promptCache) else {
            Issue.record("expected skipped, got \(String(describing: trace.outcome(for: .promptCache)))")
            return
        }
        #expect(reason.contains("no request this conversation sent"))
    }

    /// Like its siblings that read history rather than the answer, it runs before the empty-answer
    /// guard: a turn that produced no text still put a request in front of the provider.
    @Test("it runs even when the answer was empty and there is nothing to name")
    func runsBeforeTheEmptyAnswerGuard() async {
        var trace = PipelineTrace()
        let metadata = await pipeline().generate(
            userText: "hi",
            assistantText: "   ",
            sentPrompts: Layout.conversation(count: 2),
            trace: &trace
        )
        #expect(metadata == nil)
        #expect(trace.outcome(for: .promptCache) != nil)
    }

    @Test("the stage table names PromptCacheKit as its owner")
    func owner() {
        #expect(PipelineStage.promptCache.package == "PromptCacheKit")
        #expect(PipelineStage.promptCache.title == "Prompt cache")
    }
}

// MARK: - What is kept

@Suite("Sent prompts")
struct SentPromptTests {
    private func completion(firstCall: OpenRouterUsage?) -> TurnCompletion {
        TurnCompletion(
            text: "answer",
            providerID: "openrouter",
            promptTokens: 11,
            completionTokens: 4,
            reportedCostUSD: nil,
            meteredCostUSD: 0,
            attempts: 1,
            firstCall: firstCall
        )
    }

    private func turn() -> PreparedTurn {
        PreparedTurn(
            modelID: "openai/gpt-4o",
            messages: [
                LLMMessage(role: .system, content: "You are terse."),
                LLMMessage(role: .user, content: "hello")
            ],
            outboundUserText: "hello",
            displayUserText: "hello",
            sources: [],
            didCompact: false,
            estimatedInputTokens: 6
        )
    }

    @Test("a turn that recorded no provider usage is not a request that reached the provider")
    func noUsageNoRequest() {
        #expect(SentPrompt(turn: turn(), completion: completion(firstCall: nil), sentAt: Date()) == nil)
    }

    @Test("a turn that did is kept as what was sent, without the gateway's per-instance ids")
    func keptAsSent() throws {
        let usage = Layout.usage(prompt: 11, cached: 4)
        let sentAt = Date(timeIntervalSince1970: 5)
        let sent = try #require(SentPrompt(turn: turn(), completion: completion(firstCall: usage), sentAt: sentAt))

        #expect(sent.modelID == "openai/gpt-4o")
        #expect(sent.messages == [
            SentPrompt.Message(role: .system, content: "You are terse."),
            SentPrompt.Message(role: .user, content: "hello")
        ])
        #expect(sent.usage == usage)
        #expect(sent.sentAt == sentAt)
        // Two builds of the same turn carry different `LLMMessage` ids; the kept form must not.
        #expect(sent == SentPrompt(turn: turn(), completion: completion(firstCall: usage), sentAt: sentAt))
    }

    @Test("the history is capped at the window, oldest first")
    func windowed() {
        var history: [SentPrompt] = []
        for index in 0..<(SentPrompt.window + 4) {
            history = Layout.request([Layout.message(.user, "q\(index)")], at: Double(index)).appended(to: history)
        }
        #expect(history.count == SentPrompt.window)
        #expect(history.first?.messages.first?.content == "q4")
        #expect(history.last?.messages.first?.content == "q\(SentPrompt.window + 3)")
    }

    @Test("the size estimate agrees with the one the context meter uses")
    func estimateAgrees() {
        for text in ["", "a", "abcd", String(repeating: "é", count: 41), Layout.instructions()] {
            let mine = SentPrompt.Message(role: .user, content: text).estimatedTokens
            let meter = ConversationMessage(role: .user, text: text).estimatedTokens
            #expect(mine == meter, "\"\(text.prefix(8))…\" is \(mine) here and \(meter) in the composer")
        }
    }

    @Test("every role has its own tag, so an assistant reply never matches a user message")
    func roleTags() {
        let tags = [LLMMessageRole.system, .user, .assistant, .tool].map {
            SentPrompt.Message(role: $0, content: "same words").tagged
        }
        #expect(tags == ["system: same words", "user: same words", "assistant: same words", "tool: same words"])
    }
}

// MARK: - What the recorder remembers

@Suite("Usage recorder marks")
struct UsageMarkTests {
    @Test("the first call after a mark is the turn's own call, not the last hop's")
    func firstAfterMark() async {
        let recorder = UsageRecorder()
        await recorder.record(Layout.usage(prompt: 10))
        let mark = await recorder.recordCount
        await recorder.record(Layout.usage(prompt: 40))
        await recorder.record(Layout.usage(prompt: 60))

        #expect(mark == 1)
        #expect(await recorder.firstRecord(after: mark)?.promptTokens == 40)
        #expect(await recorder.mostRecent?.promptTokens == 60)
    }

    @Test("nothing recorded since the mark is nil, and a mark past a reset is not a crash")
    func nothingSinceMark() async {
        let recorder = UsageRecorder()
        await recorder.record(Layout.usage(prompt: 10))
        let mark = await recorder.recordCount
        #expect(await recorder.firstRecord(after: mark) == nil)

        await recorder.reset()
        #expect(await recorder.firstRecord(after: mark) == nil)
        #expect(await recorder.recordCount == 0)
    }
}
