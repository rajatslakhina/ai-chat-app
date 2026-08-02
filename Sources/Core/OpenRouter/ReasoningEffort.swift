import Foundation

/// How hard the model should think before answering.
///
/// These are not app-invented labels: OpenRouter takes `reasoning.effort` and allocates roughly
/// 95 / 80 / 50 / 20 percent of `max_tokens` to reasoning for xhigh / high / medium / low. So the
/// control changes what is actually sent rather than decorating the screen — which is the whole
/// bar for a setting in this app.
///
/// Ordered fastest to smartest, and the picker relies on `allCases` for that order.
enum ReasoningEffort: String, Codable, CaseIterable, Sendable, Identifiable {
    case low
    case medium
    case high
    case extra

    var id: String { rawValue }

    /// OpenRouter's own vocabulary. Everything matches except `extra`, which it calls `xhigh` —
    /// "Extra" reads better next to "High" than "xhigh" does, and the translation belongs here
    /// rather than in the view.
    var wireValue: String {
        self == .extra ? "xhigh" : rawValue
    }

    var title: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .extra: return "Extra"
        }
    }

    /// The trade being made, said plainly. "High" alone does not tell anyone what it costs them.
    var detail: String {
        switch self {
        case .low: return "Fastest, cheapest"
        case .medium: return "Balanced"
        case .high: return "Slower, more thorough"
        case .extra: return "Smartest, slowest"
        }
    }

    var symbol: String {
        switch self {
        case .low: return "hare"
        case .medium: return "gauge.medium"
        case .high: return "gauge.high"
        case .extra: return "brain"
        }
    }

    /// What a conversation uses when it has never been told otherwise.
    static let fallback = ReasoningEffort.medium
}

/// The effort the next request should carry.
///
/// A reference holder rather than a field on the provider, because `OpenRouterProvider` is a
/// struct: whoever holds it holds a copy, so there is nothing for the app to mutate. Effort is
/// per-conversation while the provider is shared and built once, so the value has to be reachable
/// from both sides — this is the smallest thing that achieves that without reshaping the provider
/// or forking `LLMRequest` to carry a field ProviderGatewayKit does not have.
///
/// `NSLock` and `@unchecked Sendable`, matching how this app already boxes shared mutable state.
/// The honest limitation: it holds one value for the whole provider, so two conversations sending
/// at the same instant would share whichever was set last. This app sends one turn at a time.
final class ReasoningEffortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ReasoningEffort?

    init(_ initial: ReasoningEffort? = nil) {
        self.stored = initial
    }

    var current: ReasoningEffort? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ effort: ReasoningEffort?) {
        lock.lock()
        defer { lock.unlock() }
        stored = effort
    }
}
