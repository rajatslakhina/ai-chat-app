import Foundation
import QuotaGovernorKit

/// Generation parameters the Settings screen owns.
///
/// Both values are clamped in `init` rather than at the call site that builds an `LLMRequest`,
/// because `LLMRequest.init` enforces them with `precondition` — and a `precondition` **traps in
/// release**. Binding a slider straight through to the request would turn an out-of-range value
/// into a crash on a shipping build instead of into a rejected request, so the clamp lives in the
/// type the UI writes to and there is no path from the UI to an unclamped number.
struct TurnSettings: Sendable, Equatable {
    /// The range `ProviderGatewayKit` enforces, copied from `LLMRequest.init` rather than guessed.
    static let temperatureRange: ClosedRange<Double> = 0...2
    static let defaultTemperature: Double = 0.7

    let temperature: Double
    let maxOutputTokens: Int

    init(temperature: Double = TurnSettings.defaultTemperature, maxOutputTokens: Int = 1_024) {
        self.temperature = Self.clamp(temperature: temperature)
        self.maxOutputTokens = max(1, maxOutputTokens)
    }

    /// Brings any `Double` into the range the provider accepts.
    ///
    /// A non-finite value is replaced rather than clamped, and that distinction matters: NaN fails
    /// `(0...2).contains(_:)` exactly the way `3.0` does, and `min(max(.nan, 0), 2)` is still NaN,
    /// so clamping alone would leave the trap in place for the one input a text field can produce
    /// by accident.
    static func clamp(temperature raw: Double) -> Double {
        guard raw.isFinite else { return defaultTemperature }
        return min(max(raw, temperatureRange.lowerBound), temperatureRange.upperBound)
    }
}

/// A ceiling on what the account may spend inside one calendar month, and what it has spent.
///
/// The spend is carried here rather than left to `QuotaGovernor` alone for one reason:
/// `QuotaGovernor`'s ledger is in memory, so a relaunch would hand the user a fresh allowance and
/// a "monthly budget" that resets every time the app is killed is not a monthly budget. The month
/// boundary and the running total are the app's job; refusing the turn that does not fit is the
/// governor's.
struct MonthlyBudget: Sendable, Equatable {
    /// `nil` is unlimited, which is emphatically not zero — a zero ceiling refuses the very first
    /// message, and defaulting a missing value to it would make an unconfigured app look broken.
    var ceilingUSD: Double?
    /// Settled spend inside `month`, in integer microcents (1e-8 USD), the unit the ledger uses.
    var spentMicrocents: Int
    /// `yyyy-MM`, the window this total belongs to.
    var month: String

    init(ceilingUSD: Double? = nil, spentMicrocents: Int = 0, month: String = MonthlyBudget.now()) {
        self.ceilingUSD = ceilingUSD
        self.spentMicrocents = max(0, spentMicrocents)
        self.month = month
    }

    /// The current window, derived from `Calendar` components rather than a `DateFormatter`, so no
    /// locale can reorder the fields and make two months compare equal.
    ///
    /// `component(_:from:)` rather than `dateComponents(_:from:)` because it returns a plain `Int`.
    /// The optional form needed two `?? 0` fallbacks that no date and no calendar could reach.
    static func now(_ date: Date = Date(), calendar: Calendar = .current) -> String {
        String(
            format: "%04d-%02d",
            calendar.component(.year, from: date),
            calendar.component(.month, from: date)
        )
    }

    /// The same ceiling in a new window, with the running total cleared.
    func rolled(to newMonth: String) -> MonthlyBudget {
        guard newMonth != month else { return self }
        return MonthlyBudget(ceilingUSD: ceilingUSD, spentMicrocents: 0, month: newMonth)
    }

    var isUnlimited: Bool { ceilingUSD == nil }

    /// The whole ceiling in microcents, or nil when there is no ceiling.
    var ceilingMicrocents: Int? {
        guard let ceilingUSD else { return nil }
        return max(0, TurnExecutor.microcents(from: ceilingUSD))
    }

    /// What is left this month. Never negative: an overrun settles after its hold is released, and
    /// the governor already refuses on the strength of that — reporting a negative allowance here
    /// would put a minus sign in front of a number the user is asked to read as "remaining".
    var remainingMicrocents: Int? {
        guard let ceiling = ceilingMicrocents else { return nil }
        return max(0, ceiling - spentMicrocents)
    }

    /// The limits the account scope is registered with.
    ///
    /// Registered against what is *left*, not against the whole ceiling, because the governor's
    /// ledger starts empty on every launch. Handing it the full ceiling would give the user their
    /// entire month's allowance back every time the app was relaunched.
    func scopeLimits() throws -> ScopeLimits {
        guard let remaining = remainingMicrocents else { return .unlimited }
        return try ScopeLimits(quota: try Quota(microcents: remaining))
    }

    var ceilingText: String {
        guard let ceilingUSD else { return "Unlimited" }
        return String(format: "$%.2f", ceilingUSD)
    }

    /// Four decimal places, matching how the key status reports credit. A chat turn costs a
    /// fraction of a cent, and two decimals would report every real month's spend as `$0.00`.
    var spentText: String { String(format: "$%.4f", Self.usdValue(microcents: spentMicrocents)) }

    var remainingText: String {
        guard let remaining = remainingMicrocents else { return "Unlimited" }
        return String(format: "$%.4f", Self.usdValue(microcents: remaining))
    }

    static func usdValue(microcents: Int) -> Double { Double(microcents) / 100_000_000 }
}
