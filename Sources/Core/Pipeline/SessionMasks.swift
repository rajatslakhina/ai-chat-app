import GuardrailKit
import SessionMaskKit

/// GuardrailKit's PII detectors, read through SessionMaskKit's detector protocol.
///
/// The vault masks with exactly the detectors `guardrailInput` redacts with, so anything the
/// guardrail removed from a message when it was typed is masked when the history re-sends it.
/// A wider detector set would protect the history better than the message it came from, which
/// reads as a fix and is really a second, inconsistent policy.
struct GuardrailSpanDetector: SpanDetector {
    let detector: any PIIDetector

    var category: MaskCategory {
        Self.category(for: detector.category)
    }

    func spans(in text: String) -> [SensitiveSpan] {
        detector.findMatches(in: text).map {
            SensitiveSpan(category: category, range: $0.range, value: $0.matchedText)
        }
    }

    /// Lower-case for addresses, digits only for the numbered categories, so `Ana@Acme.io` and
    /// `ana@acme.io`, or a card written with spaces and with dashes, share one token.
    func canonicalKey(for value: String) -> String {
        detector.category == .emailAddress ? value.lowercased() : String(value.filter(\.isNumber))
    }

    static func category(for category: PIICategory) -> MaskCategory {
        switch category {
        case .emailAddress: return .email
        case .phoneNumber: return .phone
        case .creditCard: return .card
        case .socialSecurityNumber: return .ssn
        }
    }

    static let guardrailDefaults: [any SpanDetector] = GuardrailPolicy.defaultPIIDetectors.map {
        GuardrailSpanDetector(detector: $0)
    }
}

/// One `MaskVault` per conversation, made the first time that conversation sends.
///
/// Per conversation rather than per app: a token is a promise about one value in one thread, and
/// a shared vault would let a token minted in one conversation restore in another. Held in
/// memory only. A relaunch starts every vault empty, so the first turn after it re-masks the
/// history with fresh ordinals; nothing raw is written to disk by this type.
actor SessionMasks {
    /// The key used when a caller does not name a conversation, such as a test.
    static let defaultConversation = "default"

    private let detectors: [any SpanDetector]
    private var vaults: [String: MaskVault] = [:]

    init(detectors: [any SpanDetector] = GuardrailSpanDetector.guardrailDefaults) {
        self.detectors = detectors
    }

    /// This conversation's vault, made on first use.
    func vault(for conversationID: String) throws(MaskVaultError) -> MaskVault {
        if let existing = vaults[conversationID] {
            return existing
        }
        let vault = try MaskVault(detectors: detectors)
        vaults[conversationID] = vault
        return vault
    }

    /// This conversation's vault if it has one. The answer side only restores; it never mints.
    func existingVault(for conversationID: String) -> MaskVault? {
        vaults[conversationID]
    }
}
