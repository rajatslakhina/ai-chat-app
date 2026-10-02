import StreamReleaseKit

/// The live stream used to reach the screen one fragment at a time, before anything had judged
/// it. The output guardrail runs on the finished answer, so an email address the model wrote was
/// readable for the whole stream and only redacted when the bubble was replaced at the end. Scanning
/// each fragment on its own would not help: an address split across two fragments matches in
/// neither.
///
/// `StreamReleaseKit`'s `ReleaseGate` sits in `ProviderEffectExecutor.streamOnce` instead. It holds
/// back the last few characters, scans everything streamed so far as one text, and releases only
/// what no scanner can still change. The scanners are bounded versions of `GuardrailKit`'s four
/// built-in detectors with its default placeholders, so what streams is what the review publishes.
///
/// It never refuses. Blocking stays with the output guardrail, which owns the user-facing refusal.
/// The cost is lag: the email pattern can match up to 110 characters, so the bubble trails the
/// stream by up to that much. The trace records the peak.
enum LiveStreamRelease {
    /// Bounded so a prefix and the whole answer get the same verdict; see `StreamScanner`.
    static func defaultScanners() throws -> [any StreamScanner] {
        [
            try PatternScanner(
                name: "EMAIL_ADDRESS",
                pattern: #"[A-Za-z0-9._%+-]{1,48}@[A-Za-z0-9.-]{1,48}\.[A-Za-z]{2,12}"#,
                maxMatchLength: 110,
                action: .redact(replacement: "[REDACTED:EMAIL_ADDRESS]")
            ),
            try PatternScanner(
                name: "PHONE_NUMBER",
                pattern: #"\(?\d{3}\)?[-.\s]\d{3}[-.\s]\d{4}"#,
                maxMatchLength: 14,
                action: .redact(replacement: "[REDACTED:PHONE_NUMBER]")
            ),
            try PatternScanner(
                name: "CREDIT_CARD",
                pattern: #"\b(?:\d{4}[- ]?){3}\d{4}\b"#,
                maxMatchLength: 19,
                action: .redact(replacement: "[REDACTED:CREDIT_CARD]")
            ),
            try PatternScanner(
                name: "SOCIAL_SECURITY_NUMBER",
                pattern: #"\b\d{3}-\d{2}-\d{4}\b"#,
                maxMatchLength: 11,
                action: .redact(replacement: "[REDACTED:SOCIAL_SECURITY_NUMBER]")
            )
        ]
    }

    /// The scanners to gate with, or nil when they do not compile. Nil streams unscreened, which
    /// is what the app did before this stage existed, and the trace says so.
    static func scanners(
        building build: () throws -> [any StreamScanner] = defaultScanners
    ) -> [any StreamScanner]? {
        try? build()
    }

    static let replayed: StageOutcome = .noOp(reason: "replayed an earlier result; nothing streamed")

    static let notCalled: StageOutcome = .skipped(
        reason: "the idempotency guard stopped the turn before anything streamed"
    )

    static let discarded: StageOutcome = .noOp(
        reason: "the call did not finish; text still held back was never shown"
    )

    static let unscreened: StageOutcome = .failed(
        message: "live-stream scanners did not compile; fragments were shown unscreened until review"
    )

    /// What the gate did for a turn that completed. Nil stats means no gate ran.
    static func outcome(_ stats: ReleaseStats?) -> StageOutcome {
        guard let stats else { return unscreened }
        let lag = "the bubble trailed the stream by up to \(stats.peakWithheld) character(s)"
        guard stats.redactions > 0 else {
            return .noOp(reason: "no PII in the live stream; \(lag)")
        }
        return .ran(detail: "kept \(stats.redactions) PII span(s) off the live stream; \(lag)")
    }
}
