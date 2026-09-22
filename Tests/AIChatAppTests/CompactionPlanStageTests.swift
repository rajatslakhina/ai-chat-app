import CompactionPlannerKit
import Foundation
import ProviderGatewayKit
import Testing
@testable import AIChatApp

// MARK: - Fixtures

/// Conversations built to a known size, so every figure an assertion names can be worked out by
/// hand from the arrivals rather than read back from the code under test.
///
/// Every request carries a 1,100-token system message, each question is 100 tokens and each answer
/// 300, so the first request adds 100 tokens of history and every later one adds 400: the previous
/// answer plus its own question.
private enum Plan {
    static let model = "openai/gpt-4o"

    /// 4,400 characters, which the app's characters/4 estimate makes exactly 1,100 tokens.
    static let instructions = String(repeating: "s", count: 4_400)

    /// `tokens` estimated tokens, starting with `marker` so no two texts collide.
    static func text(_ marker: String, tokens: Int) -> String {
        marker + String(repeating: "x", count: tokens * 4 - marker.count)
    }

    static func question(_ index: Int) -> SentPrompt.Message {
        SentPrompt.Message(role: .user, content: text("q\(index)", tokens: 100))
    }

    static func answer(_ index: Int) -> SentPrompt.Message {
        SentPrompt.Message(role: .assistant, content: text("a\(index)", tokens: 300))
    }

    static let system = SentPrompt.Message(role: .system, content: instructions)

    /// Request `index` as a client that never compacted would send it: the system message, every
    /// earlier exchange, then its own question.
    static func messages(at index: Int) -> [SentPrompt.Message] {
        var result = [system]
        for earlier in 0..<index {
            result += [question(earlier), answer(earlier)]
        }
        return result + [question(index)]
    }

    static func request(
        _ messages: [SentPrompt.Message],
        model: String = Plan.model,
        at seconds: Double
    ) -> SentPrompt {
        SentPrompt(
            modelID: model,
            messages: messages,
            usage: OpenRouterUsage(
                requestID: nil,
                model: model,
                promptTokens: messages.reduce(0) { $0 + $1.estimatedTokens },
                completionTokens: 5,
                cachedPromptTokens: 0,
                reportedCostUSD: nil
            ),
            sentAt: Date(timeIntervalSince1970: 1_000 + seconds)
        )
    }

    /// Seconds after the first request each of eight requests is sent: 30s apart, except a
    /// 700s pause before the seventh, past the preset's 600s cache lifetime.
    static let times: [Double] = [0, 30, 60, 90, 120, 150, 850, 880]

    /// The eight-request conversation the `.ran` assertions are worked out on.
    static func conversation(count: Int = 8) -> [SentPrompt] {
        (0..<count).map { request(messages(at: $0), at: times[$0]) }
    }

    /// A 4,000-token window with 1,024 reserved for the reply leaves 2,976 for the prompt, and
    /// 1,876 for history once the 1,100-token system message is inside it. The eight-request
    /// conversation's history runs 100, 500, 900, 1,300, 1,700, then would reach 2,100, so the
    /// sliding window compacts on the last three requests and holds 1,600.
    static func window(context: Int = 4_000, reserved: Int = 1_024) -> MetadataPipeline.CompactionWindow {
        var settings = PipelineSettings()
        settings.contextWindowTokens = context
        settings.reservedResponseTokens = reserved
        return MetadataPipeline.CompactionWindow(settings)
    }
}

// MARK: - The stage

@Suite("Compaction plan stage")
struct CompactionPlanStageTests {
    private func outcome(
        _ prompts: [SentPrompt],
        window: MetadataPipeline.CompactionWindow = Plan.window()
    ) async -> StageOutcome {
        await MetadataPipeline.compactionPlanOutcome(prompts, window: window)
    }

    private func detail(
        _ prompts: [SentPrompt],
        window: MetadataPipeline.CompactionWindow = Plan.window()
    ) async -> String {
        let result = await outcome(prompts, window: window)
        if case let .ran(text) = result { return text }
        Issue.record("expected .ran, got \(result)")
        return ""
    }

    // MARK: the paths that price nothing, and say why

    @Test("no recorded request is skipped, and the reason names what ends a turn without one")
    func nothingSent() async {
        guard case let .skipped(reason) = await outcome([]) else {
            Issue.record("expected skipped")
            return
        }
        #expect(reason.contains("no request this conversation sent has a provider-reported usage"))
        #expect(reason.contains("a cache hit, a refusal and a replayed result"))
    }

    @Test("one request is no schedule to replay")
    func oneRequest() async {
        guard case let .noOp(reason) = await outcome(Plan.conversation(count: 1)) else {
            Issue.record("expected noOp")
            return
        }
        #expect(reason.contains("only one request to openai/gpt-4o is on record"))
    }

    /// A provider's cache belongs to one model, so the run stops at the last model switch, exactly
    /// as `promptCache` reads it.
    @Test("requests before a model switch are not part of the run")
    func modelSwitch() async {
        let prompts = Plan.conversation(count: 3)
            + [Plan.request(Plan.messages(at: 3), model: "anthropic/claude-sonnet", at: 100)]
        guard case let .noOp(reason) = await outcome(prompts) else {
            Issue.record("expected noOp")
            return
        }
        #expect(reason.contains("only one request to anthropic/claude-sonnet"))
        #expect(reason.contains("since the model last changed"))
    }

    /// The common case: the app's default window is 128,000 tokens, and a conversation this size
    /// never reaches it, so the schedule decided nothing and there is nothing to price.
    @Test("a schedule that compacted nothing is a no-op naming the peak and the budget")
    func nothingCompacted() async {
        guard case let .noOp(reason) = await outcome(Plan.conversation(), window: Plan.window(context: 128_000)) else {
            Issue.record("expected noOp")
            return
        }
        #expect(reason.contains(
            "a sliding window at 125876 history tokens, \"over 125876 -> 125876\" (the 128000-token window "
                + "less 1024 reserved for the "
                + "reply and 1100 of system message)"
        ))
        #expect(reason.contains("compacted nothing over 8 requests to openai/gpt-4o"))
        #expect(reason.contains("the history peaked at about 2900 tokens against a budget of 125876"))
    }

    /// The one genuine failure: a request dated before the one ahead of it, which a device clock
    /// set backwards between two sends produces. The package refuses the trace, and the stage says
    /// the system broke rather than replaying a conversation that runs backwards.
    @Test("a request dated before the one ahead of it fails the replay")
    func clockMovedBackwards() async {
        let prompts = [
            Plan.request(Plan.messages(at: 0), at: 0),
            Plan.request(Plan.messages(at: 1), at: 60),
            Plan.request(Plan.messages(at: 2), at: 30)
        ]
        guard case let .failed(message) = await outcome(prompts) else {
            Issue.record("expected failed")
            return
        }
        #expect(message.contains("invalidTime(index: 2)"))
        #expect(message.contains("a device clock set backwards"))
    }

    // MARK: the priced path

    @Test("the app's own schedule is described from the replay")
    func scheduleLine() async {
        let text = await detail(Plan.conversation())
        #expect(text.hasPrefix(
            "the app's schedule, a sliding window at 1876 history tokens, \"over 1876 -> 1876\" (the "
                + "4000-token window less "
                + "1024 reserved for the reply and 1100 of system message), replayed over 8 requests to "
                + "openai/gpt-4o: 3 compaction(s)"
        ))
        #expect(text.contains("history tokens kept on average (peak 1700)"))
        #expect(text.contains("51.9% of prompt tokens read from the cache"))
        #expect(!text.contains("added nothing new"), "no request in this run repeated the one before it")
    }

    /// A full-budget sliding window keeps the longest history that fits on every request, so the
    /// like-for-like match is the app's own schedule and nothing is cheaper at the same history.
    @Test("like for like, nothing cheaper keeps as much history as the full-budget window")
    func likeForLike() async {
        let text = await detail(Plan.conversation())
        #expect(text.contains(
            "like for like over 272 drop-oldest schedules (targets down to 469 in steps of 93), the "
                + "cheapest that keeps at least the app's mean history is \"over 1876 -> 1876\", 0.0% cheaper "
                + "than the app's"
        ))
        #expect(text.contains("every cheaper schedule keeps less"))
    }

    @Test("giving up a tenth of the history names the cheapest schedule and what it saves")
    func lastTenPercent() async {
        let text = await detail(Plan.conversation())
        #expect(text.contains(
            "giving up the last 10% of the app's kept history (keeping at least 1046 tokens on average), "
                + "the cheapest schedule is \"over 1690 -> 1225\": "
                + "about 1050 tokens kept, 2 compaction(s), 10.8% cheaper than the app's"
        ))
    }

    @Test("a pause past the cache lifetime is counted as a lapsed cache")
    func lapsedCache() async {
        let text = await detail(Plan.conversation())
        #expect(text.contains("1 of 7 gap(s) between requests were 600s or longer"))
    }

    @Test("the scope line says the prices are illustrative and the schedule is unchanged")
    func scope() async {
        let text = await detail(Plan.conversation())
        #expect(text.contains("illustrative automatic-caching preset (free writes, reads at 0.5x, 600s "
            + "lifetime, 1024-token minimum)"))
        #expect(text.contains("only percentages are reported"))
        #expect(text.contains("estimated at 4 characters a token"))
        #expect(text.contains("the app keeps compacting to the whole window"))
        #expect(!text.contains("$"), "the preset's prices are illustrative, so no dollar figure is shown")
        // The five lines, in the order the detail promises them.
        let order = ["the app's schedule", "like for like", "giving up the last 10%", "gap(s) between", "prices come"]
        let positions = order.compactMap { text.range(of: $0)?.lowerBound }
        #expect(positions.count == order.count)
        #expect(positions == positions.sorted())
    }

    /// A retry truncates the thread and resends the same messages, so the request adds nothing.
    /// The package refuses a zero-token arrival; the request is counted as one token rather than
    /// dropped, because it was sent and its timing still decides whether the cache lapsed.
    @Test("a request that added nothing is counted as one token and named")
    func retryIsFolded() async {
        var prompts = Plan.conversation()
        prompts.insert(Plan.request(Plan.messages(at: 2), at: 70), at: 3)
        let text = await detail(prompts)
        #expect(text.contains(
            "replayed over 9 requests to openai/gpt-4o, counting 1 request(s) that added nothing new (a "
                + "retry resends the same messages) as 1 token so their timing still counts"
        ))
        #expect(text.contains("10.1% cheaper than the app's"))
    }

    /// When one turn is larger than the whole history budget, no compaction can bring a request
    /// back inside it, because a compaction keeps the newest turn. The app's schedule is then no
    /// fair reference, and no schedule in the grid is in budget to recommend.
    @Test("a turn larger than the budget leaves no fair reference and nothing to recommend")
    func turnLargerThanTheBudget() async {
        // 1,500 - 100 - 1,100 leaves 300 tokens of history, and every later request adds 400.
        let text = await detail(Plan.conversation(count: 3), window: Plan.window(context: 1_500, reserved: 100))
        #expect(text.contains("2 compaction(s)"))
        #expect(text.contains("the app's own schedule let 2 request(s) carry more than 300 history tokens"))
        #expect(text.contains(
            "no schedule in the grid keeps every request inside 300 history tokens, so none can be "
                + "recommended at 270 tokens kept on average"
        ))
    }

    /// Nothing here is something the user did or can undo, so no path raises a banner.
    @Test("no path refuses")
    func neverRefuses() async {
        let paths: [([SentPrompt], MetadataPipeline.CompactionWindow)] = [
            ([], Plan.window()),
            (Plan.conversation(count: 1), Plan.window()),
            (Plan.conversation(), Plan.window(context: 128_000)),
            (Plan.conversation(), Plan.window()),
            (Plan.conversation(count: 3), Plan.window(context: 1_500, reserved: 100)),
            ([Plan.request(Plan.messages(at: 0), at: 9), Plan.request(Plan.messages(at: 1), at: 0)], Plan.window())
        ]
        for (prompts, window) in paths {
            let result = await outcome(prompts, window: window)
            #expect(!result.isRefusal)
        }
    }
}

// MARK: - Reading the run

@Suite("Compaction plan setup")
struct CompactionPlanSetupTests {
    private func setup(
        _ run: [SentPrompt],
        window: MetadataPipeline.CompactionWindow = Plan.window()
    ) throws -> CompactionPlanSetup {
        let latest = try #require(run.last)
        return try CompactionPlanSetup(run, latest: latest, window: window)
    }

    @Test("each request arrives as what it added, at its offset from the first")
    func arrivals() throws {
        let read = try setup(Plan.conversation())
        #expect(read.trace.turns.map(\.tokens) == [100, 400, 400, 400, 400, 400, 400, 400])
        #expect(read.trace.turns.map(\.time) == Plan.times)
        #expect(read.trace.stablePrefixTokens == 1_100)
        #expect(read.stablePrefixTokens == 1_100)
        #expect(read.historyBudget == 1_876)
        #expect(read.folded == 0)
        let appSchedule = try CompactionPolicy.slidingWindow(budget: 1_876)
        #expect(read.policy == appSchedule)
        #expect(read.grid.floor == 469)
        #expect(read.grid.step == 93)
    }

    /// The app's compactor drops turns from the front of the request. That must not read as the
    /// conversation shrinking: the package's history grows by arrivals and the replay does the
    /// dropping itself.
    @Test("a request the app already compacted still arrives as only what it added")
    func compactedRequest() throws {
        let compacted = [Plan.system, Plan.question(1), Plan.answer(1), Plan.question(2)]
        let run = [
            Plan.request(Plan.messages(at: 0), at: 0),
            Plan.request(Plan.messages(at: 1), at: 30),
            Plan.request(compacted, at: 60)
        ]
        #expect(try setup(run).trace.turns.map(\.tokens) == [100, 400, 400])
    }

    @Test("a message sent twice counts twice, because it is compared as a multiset")
    func repeatedMessage() {
        let hello = SentPrompt.Message(role: .user, content: Plan.text("hi", tokens: 5))
        let reply = SentPrompt.Message(role: .assistant, content: Plan.text("ok", tokens: 7))
        #expect(CompactionPlanSetup.addedTokens([hello, reply, hello], after: [hello]) == 12)
        #expect(CompactionPlanSetup.addedTokens([hello], after: [hello, reply, hello]) == 0)
    }

    @Test("a system message is the stable prefix, never part of what a request added")
    func systemIsNotHistory() {
        let changedSystem = SentPrompt.Message(role: .system, content: Plan.text("new rules", tokens: 50))
        #expect(CompactionPlanSetup.addedTokens([changedSystem, Plan.question(0)], after: [Plan.system]) == 100)
    }

    @Test("with no system message there is no stable prefix and the whole prompt is history")
    func noSystemMessage() throws {
        let run = (0..<2).map { Plan.request(Array(Plan.messages(at: $0).dropFirst()), at: Double($0)) }
        let read = try setup(run)
        #expect(read.stablePrefixTokens == 0)
        #expect(read.historyBudget == 2_976)
    }

    /// Settings could reserve more than the window holds. The compactor would then have nothing to
    /// keep; the audit still replays, at the smallest budget the package accepts.
    @Test("a window smaller than its reserve still replays, at a budget of one token")
    func degenerateWindow() async throws {
        let window = Plan.window(context: 1_000, reserved: 1_024)
        let read = try setup(Plan.conversation(count: 2), window: window)
        #expect(read.historyBudget == 1)
        #expect(read.grid.floor == 0)
        #expect(read.grid.step == 1)
        let result = await MetadataPipeline.compactionPlanOutcome(Plan.conversation(count: 2), window: window)
        guard case let .ran(text) = result else {
            Issue.record("expected ran, got \(result)")
            return
        }
        #expect(text.contains("let 2 request(s) carry more than 1 history tokens"))
    }

    @Test("the window is read from the compactor's settings, defaults included")
    func windowFromSettings() {
        let defaults = MetadataPipeline.CompactionWindow()
        #expect(defaults.contextWindowTokens == PipelineSettings().contextWindowTokens)
        #expect(defaults.reservedResponseTokens == PipelineSettings().reservedResponseTokens)
        #expect(defaults.promptTokens == 128_000 - 1_024)
        #expect(Plan.window().promptTokens == 2_976)
    }
}

// MARK: - On the trace

@Suite("Compaction plan stage on the trace")
struct CompactionPlanTraceTests {
    private func pipeline() async throws -> MetadataPipeline {
        try await MetadataHarness.pipeline(
            completer: ScriptedCompleter(
                title: [MetadataHarness.goodTitle],
                followUps: [MetadataHarness.goodFollowUps]
            )
        )
    }

    @Test("the audit records exactly one compactionPlan entry, with the outcome the prompts earn")
    func recordsOnce() async throws {
        var trace = PipelineTrace()
        try await pipeline().auditCompactionPlan(trace: &trace, prompts: Plan.conversation(), window: Plan.window())
        #expect(trace.records.filter { $0.stage == .compactionPlan }.count == 1)
        guard case let .ran(detail) = trace.outcome(for: .compactionPlan) else {
            Issue.record("expected ran")
            return
        }
        #expect(detail.contains("replayed over 8 requests to openai/gpt-4o"))
        #expect(trace.refusal == nil)
    }

    @Test("a generation with no request history records an honest skip rather than guessing")
    func generateWithoutHistory() async throws {
        var trace = PipelineTrace()
        _ = try await pipeline().generate(userText: "hi", assistantText: "hello", trace: &trace)
        guard case let .skipped(reason) = trace.outcome(for: .compactionPlan) else {
            Issue.record("expected skipped, got \(String(describing: trace.outcome(for: .compactionPlan)))")
            return
        }
        #expect(reason.contains("no request this conversation sent"))
    }

    /// With no window passed, the audit replays the settings' default, which is the window a
    /// caller that never changed it compacted against: 128,000 tokens, where this conversation
    /// compacts nothing.
    @Test("generate replays the default window unless it is given the compactor's own")
    func generateUsesTheWindow() async throws {
        var defaulted = PipelineTrace()
        _ = try await pipeline().generate(
            userText: "hi",
            assistantText: "hello",
            sentPrompts: Plan.conversation(),
            trace: &defaulted
        )
        guard case let .noOp(reason) = defaulted.outcome(for: .compactionPlan) else {
            Issue.record("expected noOp, got \(String(describing: defaulted.outcome(for: .compactionPlan)))")
            return
        }
        #expect(reason.contains("the 128000-token window"))

        var given = PipelineTrace()
        _ = try await pipeline().generate(
            userText: "hi",
            assistantText: "hello",
            sentPrompts: Plan.conversation(),
            compactionWindow: Plan.window(),
            trace: &given
        )
        guard case let .ran(detail) = given.outcome(for: .compactionPlan) else {
            Issue.record("expected ran, got \(String(describing: given.outcome(for: .compactionPlan)))")
            return
        }
        #expect(detail.contains("the 4000-token window"))
    }

    /// Like `promptCache`, it reads requests already sent rather than this turn's answer, so it
    /// runs before the empty-answer guard and immediately after `promptCache`.
    @Test("it runs right after promptCache, even when the answer was empty")
    func runsAfterPromptCache() async throws {
        var trace = PipelineTrace()
        let metadata = try await pipeline().generate(
            userText: "hi",
            assistantText: "   ",
            sentPrompts: Plan.conversation(count: 2),
            trace: &trace
        )
        #expect(metadata == nil)
        let stages = trace.records.map(\.stage)
        let cache = try #require(stages.firstIndex(of: .promptCache))
        #expect(stages.firstIndex(of: .compactionPlan) == cache + 1)
    }

    @Test("the stage table names CompactionPlannerKit as its owner")
    func owner() {
        #expect(PipelineStage.compactionPlan.package == "CompactionPlannerKit")
        #expect(PipelineStage.compactionPlan.title == "Compaction plan")
    }
}
