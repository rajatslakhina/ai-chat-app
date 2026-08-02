import Foundation
import ProviderGatewayKit
import QuotaGovernorKit
import Testing
@testable import AIChatApp

@Suite("Turn settings")
struct TurnSettingsTests {
    @Test("a temperature above the range is clamped rather than passed through")
    func clampsHigh() {
        #expect(TurnSettings(temperature: 3.5).temperature == 2)
        #expect(TurnSettings(temperature: 2).temperature == 2)
    }

    @Test("a negative temperature is clamped to zero")
    func clampsLow() {
        #expect(TurnSettings(temperature: -1).temperature == 0)
    }

    /// The case a bare `min(max(...))` would let through: NaN survives clamping unchanged and
    /// fails `(0...2).contains(_:)` exactly the way `3.0` does.
    @Test("a non-finite temperature is replaced, not clamped")
    func replacesNonFinite() {
        #expect(TurnSettings(temperature: .nan).temperature == TurnSettings.defaultTemperature)
        #expect(TurnSettings(temperature: .infinity).temperature == TurnSettings.defaultTemperature)
        #expect(
            TurnSettings(temperature: -.infinity).temperature == TurnSettings.defaultTemperature
        )
    }

    @Test("maxOutputTokens is never zero, which LLMRequest also rejects with a precondition")
    func positiveTokens() {
        #expect(TurnSettings(maxOutputTokens: 0).maxOutputTokens == 1)
        #expect(TurnSettings(maxOutputTokens: -9).maxOutputTokens == 1)
        #expect(TurnSettings(maxOutputTokens: 512).maxOutputTokens == 512)
    }

    /// The whole point of the clamp: every value the UI can produce must build a request without
    /// tripping either precondition. A trap here would be a crash in a release build.
    @Test("every clamped value builds an LLMRequest")
    func clampedValuesAreAccepted() {
        for raw in [-100.0, -0.01, 0, 0.7, 1.999, 2, 2.01, 99, .nan, .infinity] {
            let settings = TurnSettings(temperature: raw)
            let request = LLMRequest(
                messages: [LLMMessage(role: .user, content: "hi")],
                maxOutputTokens: settings.maxOutputTokens,
                temperature: settings.temperature
            )
            #expect(TurnSettings.temperatureRange.contains(request.temperature))
        }
    }
}

@Suite("Monthly budget")
struct MonthlyBudgetTests {
    private func date(_ year: Int, _ month: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = 15
        return Calendar(identifier: .gregorian).date(from: components) ?? Date()
    }

    @Test("the month key is zero-padded and sorts lexically")
    func monthKey() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        #expect(MonthlyBudget.now(date(2026, 7), calendar: calendar) == "2026-07")
        #expect(MonthlyBudget.now(date(2026, 11), calendar: calendar) == "2026-11")
        #expect("2026-07" < "2026-11", "a padded key must order correctly as a string")
    }

    @Test("rolling into a new month clears the running total but keeps the ceiling")
    func rolls() {
        let july = MonthlyBudget(ceilingUSD: 5, spentMicrocents: 400_000, month: "2026-07")
        let august = july.rolled(to: "2026-08")
        #expect(august.spentMicrocents == 0)
        #expect(august.ceilingUSD == 5)
        #expect(july.rolled(to: "2026-07") == july, "the same month must not reset anything")
    }

    @Test("an absent ceiling is unlimited, and unlimited is not zero")
    func unlimited() throws {
        let budget = MonthlyBudget()
        #expect(budget.isUnlimited)
        #expect(budget.remainingMicrocents == nil)
        #expect(budget.remainingText == "Unlimited")
        #expect(try budget.scopeLimits().quota.microcents == nil)
    }

    /// A zero ceiling is a real ceiling. It has to reach the governor as `0`, not as "unset".
    @Test("a zero ceiling registers as a real limit of zero")
    func zeroCeiling() throws {
        let budget = MonthlyBudget(ceilingUSD: 0)
        #expect(!budget.isUnlimited)
        #expect(try budget.scopeLimits().quota.microcents == 0)
    }

    /// The reason the app keeps its own total: the governor's ledger is empty at every launch, so
    /// it must be registered against what is *left*, never against the whole ceiling.
    @Test("the ledger is registered against the remainder, not the whole ceiling")
    func registersRemainder() throws {
        let budget = MonthlyBudget(ceilingUSD: 1, spentMicrocents: 40_000_000)
        #expect(budget.ceilingMicrocents == 100_000_000)
        #expect(budget.remainingMicrocents == 60_000_000)
        #expect(try budget.scopeLimits().quota.microcents == 60_000_000)
    }

    @Test("an overspent month reports zero left rather than a negative allowance")
    func overspent() {
        let budget = MonthlyBudget(ceilingUSD: 1, spentMicrocents: 150_000_000)
        #expect(budget.remainingMicrocents == 0)
        #expect(budget.remainingText == "$0.0000")
    }

    @Test("spend is shown to four decimals, because a turn costs a fraction of a cent")
    func formatting() {
        let budget = MonthlyBudget(ceilingUSD: 5, spentMicrocents: 10_400)
        #expect(budget.ceilingText == "$5.00")
        #expect(budget.spentText == "$0.0001")
        #expect(MonthlyBudget().ceilingText == "Unlimited")
    }
}

/// Records what reached the actors, in order.
private actor RecordingGraph: SettingsApplying {
    private(set) var applied: [SettingsSnapshot] = []

    func apply(_ snapshot: SettingsSnapshot) async {
        applied.append(snapshot)
    }

    func snapshots() -> [SettingsSnapshot] { applied }
}

@MainActor
@Suite("Settings store")
struct AppSettingsStoreTests {
    private func store(
        persistence: any SettingsPersisting = InMemorySettings(),
        month: String = "2026-07"
    ) -> AppSettingsStore {
        var components = DateComponents()
        components.year = Int(month.prefix(4))
        components.month = Int(month.suffix(2))
        components.day = 15
        let date = Calendar(identifier: .gregorian).date(from: components) ?? Date()
        return AppSettingsStore(persistence: persistence, clock: { date })
    }

    @Test("defaults are a working configuration when nothing has been saved")
    func defaults() {
        let settings = store()
        #expect(settings.defaultModelID == PipelineSettings().defaultModelID)
        #expect(settings.temperature == TurnSettings.defaultTemperature)
        #expect(settings.budget.isUnlimited)
        #expect(settings.budget.month == "2026-07")
    }

    @Test("every knob survives a relaunch")
    func roundTrip() {
        let disk = InMemorySettings()
        let first = store(persistence: disk)
        first.defaultModelID = "anthropic/claude-sonnet-4"
        first.temperature = 1.25
        first.budgetCeilingUSD = 12.5
        first.cacheEnabled = false
        first.routingEnabled = false

        let second = store(persistence: disk)
        #expect(second.defaultModelID == "anthropic/claude-sonnet-4")
        #expect(second.temperature == 1.25)
        #expect(second.budgetCeilingUSD == 12.5)
        #expect(!second.cacheEnabled)
        #expect(!second.routingEnabled)
        #expect(second.memoryEnabled, "an untouched flag keeps its default")
    }

    /// The reason the persisted form is a separate type: a synthesised `Decodable` on
    /// `TurnSettings` would write straight past its clamping initializer, and this value would come
    /// back at 5.0 and trap inside `LLMRequest` on the first send.
    @Test("a temperature tampered with on disk is clamped when it is read back")
    func clampsPersistedTemperature() throws {
        let json = """
        {"defaultModelID":"openai/gpt-4o","temperature":5,"maxOutputTokens":1024,
         "budgetSpentMicrocents":0,"budgetMonth":"2026-07","retrievalEnabled":true,
         "memoryEnabled":true,"cacheEnabled":true,"routingEnabled":true}
        """
        let settings = store(persistence: InMemorySettings(seed: Data(json.utf8)))
        #expect(settings.temperature == 2)
    }

    @Test("an unreadable blob falls back to defaults rather than refusing to launch")
    func corruptedBlob() {
        let settings = store(persistence: InMemorySettings(seed: Data("{ not json".utf8)))
        #expect(settings.temperature == TurnSettings.defaultTemperature)
        #expect(settings.defaultModelID == PipelineSettings().defaultModelID)
    }

    @Test("the clamp applies to what the UI writes, not only to what it reads")
    func clampsWrites() {
        let settings = store()
        settings.temperature = 9
        #expect(settings.temperature == 2)
        settings.temperature = -3
        #expect(settings.temperature == 0)
    }

    @Test("spend accumulates and rolls into a new month")
    func spend() {
        let disk = InMemorySettings()
        let july = store(persistence: disk, month: "2026-07")
        july.budgetCeilingUSD = 5
        july.recordSpend(microcents: 10_000)
        july.recordSpend(microcents: 5_000)
        #expect(july.budget.spentMicrocents == 15_000)

        let august = store(persistence: disk, month: "2026-08")
        #expect(august.budget.month == "2026-08")
        #expect(august.budget.spentMicrocents == 0, "a new month starts the allowance again")
        #expect(august.budget.ceilingUSD == 5, "the ceiling itself is not a monthly thing")
    }

    @Test("a zero or negative settlement is not added to the total")
    func ignoresEmptySpend() {
        let settings = store()
        settings.recordSpend(microcents: 0)
        settings.recordSpend(microcents: -50)
        #expect(settings.budget.spentMicrocents == 0)
    }

    @Test("connecting pushes the loaded settings into the graph before anything is changed")
    func connectApplies() async {
        let disk = InMemorySettings()
        let first = store(persistence: disk)
        first.defaultModelID = "google/gemini-2.5-flash-lite"

        let graph = RecordingGraph()
        let second = store(persistence: disk)
        await second.connect(to: graph)

        let applied = await graph.snapshots()
        #expect(applied.count == 1)
        #expect(applied.first?.pipeline.defaultModelID == "google/gemini-2.5-flash-lite")
    }

    /// `PreModelPipeline.update` replaces the whole value rather than merging, so an older
    /// snapshot landing after a newer one would silently undo the newer change.
    @Test("changes reach the graph in the order they were made")
    func appliesInOrder() async throws {
        let graph = RecordingGraph()
        let settings = store()
        await settings.connect(to: graph)

        settings.temperature = 0.1
        settings.temperature = 0.9
        settings.defaultModelID = "openai/gpt-4o-mini"
        try await Task.sleep(nanoseconds: 50_000_000)

        let applied = await graph.snapshots()
        #expect(applied.count == 4, "one for connect, three for the changes")
        #expect(applied.map(\.turn.temperature) == [0.7, 0.1, 0.9, 0.9])
        #expect(applied.last?.pipeline.defaultModelID == "openai/gpt-4o-mini")
    }

    @Test("writing the value it already has is not an apply")
    func noOpWrite() async throws {
        let graph = RecordingGraph()
        let settings = store()
        await settings.connect(to: graph)
        settings.temperature = TurnSettings.defaultTemperature
        settings.cacheEnabled = true
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(await graph.snapshots().count == 1)
    }

    @Test("clearing the ceiling is unlimited; setting it to zero is a real zero")
    func ceilingNilVersusZero() {
        let settings = store()
        settings.budgetCeilingUSD = 0
        #expect(settings.budget.isUnlimited == false)
        #expect(settings.budget.ceilingMicrocents == 0)
        settings.budgetCeilingUSD = nil
        #expect(settings.budget.isUnlimited)
        settings.budgetCeilingUSD = -4
        #expect(settings.budgetCeilingUSD == 0, "a negative ceiling is meaningless, not unlimited")
    }
}

@Suite("Key masking")
struct SecretMaskTests {
    @Test("a real key shows its prefix and last four")
    func masksLongKey() {
        #expect(AppSecrets.mask("sk-or-v1-c4d0000000000000000906") == "sk-or-v1…0906")
    }

    /// "Prefix plus suffix" would leak most of a short string, so a short one is hidden entirely.
    @Test("a short value is replaced rather than partly revealed")
    func masksShortKey() {
        #expect(AppSecrets.mask("abcd1234") == "••••••••")
        #expect(!AppSecrets.mask("abcd1234").contains("abcd"))
    }
}
