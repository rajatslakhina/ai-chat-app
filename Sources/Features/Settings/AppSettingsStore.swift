import Foundation
import SwiftUI

/// Everything the Settings and Model Picker screens write, in one value.
struct SettingsSnapshot: Sendable, Equatable {
    var pipeline: PipelineSettings
    var turn: TurnSettings
    var budget: MonthlyBudget
}

/// The object graph, as the settings screens see it.
///
/// A protocol so the store can be exercised without building twenty-five packages: the question
/// these settings raise is "did the right values reach the actors, in the right order", and that is
/// answerable against a recorder.
protocol SettingsApplying: Sendable {
    func apply(_ snapshot: SettingsSnapshot) async
}

/// Where the settings survive a relaunch.
protocol SettingsPersisting: Sendable {
    func loadSettings() -> Data?
    func saveSettings(_ data: Data)
}

struct UserDefaultsSettings: SettingsPersisting {
    /// The key every build before profiles wrote to. Still read, once, so an existing user's
    /// model, budget and temperature survive the upgrade instead of silently resetting.
    static let legacyKey = "settings.v1"

    static func key(profileID: UUID?) -> String {
        guard let profileID else { return legacyKey }
        return "\(legacyKey).\(profileID.uuidString)"
    }

    /// `UserDefaults` is documented as thread-safe but is not annotated `Sendable`, so the
    /// compiler cannot see that. The alternative — storing a suite name and re-resolving on every
    /// read — trades a real allocation on each access for a promise the platform already makes.
    nonisolated(unsafe) let defaults: UserDefaults
    let profileID: UUID?

    init(defaults: UserDefaults = .standard, profileID: UUID? = nil) {
        self.defaults = defaults
        self.profileID = profileID
    }

    /// Falls back to the pre-profile blob exactly once — on a scoped key that has never been
    /// written. After the first save the scoped key exists and the legacy one is never consulted
    /// again, so two profiles cannot both inherit it and then diverge from a shared ancestor.
    func loadSettings() -> Data? {
        let scoped = Self.key(profileID: profileID)
        if let data = defaults.data(forKey: scoped) { return data }
        guard profileID != nil else { return nil }
        return defaults.data(forKey: Self.legacyKey)
    }

    func saveSettings(_ data: Data) {
        defaults.set(data, forKey: Self.key(profileID: profileID))
    }
}

/// Settings that vanish with the process. Used under `-UITestMode`, for the same reason
/// `InMemoryKeychain` is: a UI test that inherited the last run's model choice passes on this
/// machine and fails on the next one.
final class InMemorySettings: SettingsPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?

    init(seed: Data? = nil) {
        self.stored = seed
    }

    func loadSettings() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func saveSettings(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        stored = data
    }
}

/// The on-disk form.
///
/// Deliberately a separate, flat type rather than `Codable` on the live structs. A synthesised
/// `Decodable` conformance on `TurnSettings` would write straight into its stored properties and
/// skip the clamp in its initializer — so a temperature of `5` left behind by an older build, or
/// by anyone with a plist editor, would come back unclamped and trap inside `LLMRequest` on the
/// first send. Everything read here goes back through the real initializers.
private struct PersistedSettings: Codable {
    var defaultModelID: String
    var temperature: Double
    var maxOutputTokens: Int
    var budgetCeilingUSD: Double?
    var budgetSpentMicrocents: Int
    var budgetMonth: String
    var retrievalEnabled: Bool
    var memoryEnabled: Bool
    var cacheEnabled: Bool
    var routingEnabled: Bool
    /// Optional, unlike every field above it, and that is the point: a non-optional field added to
    /// `settings.v1` makes every blob written by an earlier build fail to decode — and the
    /// fallback in `init` then silently resets the user's model, budget and temperature along with
    /// it. An absent key reads as "off", which is also the default.
    var toolApprovalRequired: Bool?

    init(_ snapshot: SettingsSnapshot) {
        defaultModelID = snapshot.pipeline.defaultModelID
        temperature = snapshot.turn.temperature
        maxOutputTokens = snapshot.turn.maxOutputTokens
        budgetCeilingUSD = snapshot.budget.ceilingUSD
        budgetSpentMicrocents = snapshot.budget.spentMicrocents
        budgetMonth = snapshot.budget.month
        retrievalEnabled = snapshot.pipeline.retrievalEnabled
        memoryEnabled = snapshot.pipeline.memoryEnabled
        cacheEnabled = snapshot.pipeline.cacheEnabled
        routingEnabled = snapshot.pipeline.routingEnabled
        toolApprovalRequired = snapshot.pipeline.toolApprovalRequired
    }

    func snapshot(month: String) -> SettingsSnapshot {
        var pipeline = PipelineSettings()
        pipeline.defaultModelID = defaultModelID
        pipeline.retrievalEnabled = retrievalEnabled
        pipeline.memoryEnabled = memoryEnabled
        pipeline.cacheEnabled = cacheEnabled
        pipeline.routingEnabled = routingEnabled
        pipeline.toolApprovalRequired = toolApprovalRequired ?? false
        return SettingsSnapshot(
            pipeline: pipeline,
            turn: TurnSettings(temperature: temperature, maxOutputTokens: maxOutputTokens),
            budget: MonthlyBudget(
                ceilingUSD: budgetCeilingUSD,
                spentMicrocents: budgetSpentMicrocents,
                month: budgetMonth
            )
            .rolled(to: month)
        )
    }
}

/// The single writer for every user-adjustable knob.
///
/// One store rather than a `@State` per screen: the model picker and the Settings screen both edit
/// `PipelineSettings`, and two independent copies would race — whichever screen closed last would
/// win, silently reverting the other's change.
@MainActor
@Observable
final class AppSettingsStore {
    private(set) var snapshot: SettingsSnapshot

    private var persistence: any SettingsPersisting
    private let clock: @Sendable () -> Date
    private var target: (any SettingsApplying)?
    /// The tail of the apply chain. Settings changes are applied strictly in the order they were
    /// made — two unawaited `Task`s would let an older snapshot land after a newer one, and
    /// `PreModelPipeline.update` replaces the whole value rather than merging.
    private var applyTask: Task<Void, Never>?

    init(
        persistence: any SettingsPersisting = UserDefaultsSettings(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.persistence = persistence
        self.clock = clock
        let month = MonthlyBudget.now(clock())
        guard let data = persistence.loadSettings(),
              let decoded = try? JSONDecoder().decode(PersistedSettings.self, from: data) else {
            // A missing or unreadable blob is not an error worth surfacing: the defaults are a
            // working configuration, and refusing to launch over a settings file would be worse
            // than starting from them.
            self.snapshot = SettingsSnapshot(
                pipeline: PipelineSettings(),
                turn: TurnSettings(),
                budget: MonthlyBudget(month: month)
            )
            return
        }
        self.snapshot = decoded.snapshot(month: month)
    }

    /// Attaches the object graph and pushes the loaded settings into it.
    ///
    /// Separate from `init` because the graph is built asynchronously after the first screen is
    /// up, and the store has to exist before that to render Settings at all.
    func connect(to graph: any SettingsApplying) async {
        target = graph
        await graph.apply(snapshot)
    }

    // MARK: - Writes

    var defaultModelID: String {
        get { snapshot.pipeline.defaultModelID }
        set { mutate { $0.pipeline.defaultModelID = newValue } }
    }

    /// Clamped on the way in, so an out-of-range value cannot be persisted and read back later.
    var temperature: Double {
        get { snapshot.turn.temperature }
        set {
            mutate {
                $0.turn = TurnSettings(
                    temperature: newValue,
                    maxOutputTokens: $0.turn.maxOutputTokens
                )
            }
        }
    }

    /// `nil` clears the ceiling. Zero does not: it is a real ceiling that refuses everything.
    var budgetCeilingUSD: Double? {
        get { snapshot.budget.ceilingUSD }
        set { mutate { $0.budget.ceilingUSD = newValue.map { max(0, $0) } } }
    }

    var retrievalEnabled: Bool {
        get { snapshot.pipeline.retrievalEnabled }
        set { mutate { $0.pipeline.retrievalEnabled = newValue } }
    }

    var memoryEnabled: Bool {
        get { snapshot.pipeline.memoryEnabled }
        set { mutate { $0.pipeline.memoryEnabled = newValue } }
    }

    var cacheEnabled: Bool {
        get { snapshot.pipeline.cacheEnabled }
        set { mutate { $0.pipeline.cacheEnabled = newValue } }
    }

    var routingEnabled: Bool {
        get { snapshot.pipeline.routingEnabled }
        set { mutate { $0.pipeline.routingEnabled = newValue } }
    }

    var toolApprovalRequired: Bool {
        get { snapshot.pipeline.toolApprovalRequired }
        set { mutate { $0.pipeline.toolApprovalRequired = newValue } }
    }

    var budget: MonthlyBudget { snapshot.budget }

    /// Adds a settled turn's cost to the month's total.
    ///
    /// Not routed through `mutate`: re-applying the snapshot here would rebuild the ledger on
    /// every single turn, which is the one thing `TurnExecutor.setBudget` defers precisely to
    /// avoid. The total is persisted; the governor already knows about this spend.
    func recordSpend(microcents: Int) {
        guard microcents > 0 else { return }
        snapshot.budget = snapshot.budget.rolled(to: MonthlyBudget.now(clock()))
        snapshot.budget.spentMicrocents += microcents
        persist()
    }

    private func mutate(_ change: (inout SettingsSnapshot) -> Void) {
        var updated = snapshot
        change(&updated)
        guard updated != snapshot else { return }
        snapshot = updated
        persist()
        schedule(updated)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(PersistedSettings(snapshot)) else { return }
        persistence.saveSettings(data)
    }

    /// Points the store at another profile's settings and pushes them into the graph.
    ///
    /// The whole snapshot is replaced rather than merged: these are a different person's choices,
    /// and merging would carry one profile's model or budget into another's.
    func switchProfile(to profileID: UUID, defaults: UserDefaults = .standard) {
        let scoped = UserDefaultsSettings(defaults: defaults, profileID: profileID)
        reload(persistence: scoped)
    }

    /// Swaps the backing store and reloads. Not private so a test can drive it without
    /// `UserDefaults`.
    func reload(persistence newPersistence: any SettingsPersisting) {
        persistence = newPersistence
        let month = MonthlyBudget.now(clock())
        guard let data = newPersistence.loadSettings(),
              let decoded = try? JSONDecoder().decode(PersistedSettings.self, from: data) else {
            snapshot = SettingsSnapshot(
                pipeline: PipelineSettings(),
                turn: TurnSettings(),
                budget: MonthlyBudget(month: month)
            )
            schedule(snapshot)
            return
        }
        snapshot = decoded.snapshot(month: month)
        schedule(snapshot)
    }

    private func schedule(_ value: SettingsSnapshot) {
        let previous = applyTask
        let graph = target
        applyTask = Task {
            await previous?.value
            await graph?.apply(value)
        }
    }
}
