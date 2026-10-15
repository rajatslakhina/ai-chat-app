import LinkEgressKit
import ProviderGatewayKit
import SessionMaskKit

extension PostModelPipeline {
    /// `.standard`, except that an image is reported rather than removed. SwiftUI's `Text` shows an
    /// image's alt text and never fetches the URL, so a notice saying "images load without a tap"
    /// would be false in this app. An image URL is still checked for what it carries, and one that
    /// carries conversation data is removed exactly like a link.
    static let linkPolicy: LinkPolicy = {
        var policy = LinkPolicy.standard
        policy.actions[.imageAutoload] = .keep
        return policy
    }()

    /// Every link the answer writes, judged before the session tokens in it are restored.
    ///
    /// Before the restore, and that order is the point. The model never sees the user's address,
    /// only `[EMAIL_1]`, so a link it writes for a prompt injection carries the token. The restore
    /// stage would turn that token into the address inside the URL, and `Text` would make it a
    /// link one tap from the attacker's server. The output guardrail redacts an address it can
    /// match, but not a booking reference, a retrieved passage or the system prompt, and not the
    /// same text Base64- or percent-encoded.
    ///
    /// No refusal. The answer is delivered; each removed link is replaced by its visible text and a
    /// notice saying where it went and why, at the place the user would have tapped. The detail
    /// reaches Diagnostics.
    static func checkLinks(
        _ answer: String,
        context: EgressContext,
        trace: inout PipelineTrace
    ) -> (text: String, modified: Bool) {
        let report = LinkSanitizer(policy: linkPolicy).sanitize(answer, context: context)
        guard !report.links.isEmpty else {
            trace.record(.linkEgress, .noOp(reason: "no links in the answer"))
            return (answer, false)
        }
        guard report.isChanged else {
            trace.record(.linkEgress, .noOp(reason: describeKept(report)))
            return (answer, false)
        }
        trace.record(.linkEgress, .ran(detail: describeChanged(report)))
        return (report.text, true)
    }

    /// The conversation's session tokens as the values that must not leave, and what the model
    /// was sent this turn as the text an exfiltrating URL would carry.
    func linkContext(
        conversationID: String,
        messages: [LLMMessage],
        sources: [RetrievedSource]
    ) async -> EgressContext {
        var values: [SensitiveValue] = []
        if let vault = await masks.existingVault(for: conversationID) {
            values = await vault.snapshot().entries.map {
                SensitiveValue(label: Self.label(for: $0.token.category), value: "\($0.token)")
            }
        }
        let sent = messages.compactMap(Self.egressSource(for:))
        let passages = sources.map {
            EgressSource(label: "a retrieved passage", text: $0.snippet, origin: .retrieved)
        }
        return EgressContext(sensitiveValues: values, sources: sent + passages)
    }

    /// The model's own earlier answers are left out: a link it repeats from them is not text it
    /// was handed this turn.
    static func egressSource(for message: LLMMessage) -> EgressSource? {
        switch message.role {
        case .system: return EgressSource(label: "the system prompt", text: message.content, origin: .system)
        case .user: return EgressSource(label: "your messages", text: message.content, origin: .user)
        case .tool: return EgressSource(label: "a tool result", text: message.content, origin: .tool)
        case .assistant: return nil
        }
    }

    static func label(for category: MaskCategory) -> String {
        switch category {
        case .email: return "your email address"
        case .phone: return "your phone number"
        case .card: return "your card number"
        case .ssn: return "your social security number"
        default: return "a masked value"
        }
    }

    static func describeKept(_ report: LinkReport) -> String {
        let reported = report.findings.map(\.kind.rawValue)
        let note = reported.isEmpty ? "" : "; reported, kept: " + reported.joined(separator: ", ")
        return "checked \(report.links.count) link(s); none carried conversation data" + note
    }

    static func describeChanged(_ report: LinkReport) -> String {
        var parts: [String] = []
        if !report.unlinked.isEmpty {
            parts.append("unlinked \(report.unlinked.count) of \(report.links.count) link(s): "
                + describe(report.unlinked))
        }
        if !report.annotated.isEmpty {
            parts.append("annotated \(report.annotated.count): " + describe(report.annotated))
        }
        return parts.joined(separator: "; ")
    }

    /// Each link's host and the reason the reader's notice gives. Only changed links are passed,
    /// and every changed link has a deciding finding.
    static func describe(_ links: [JudgedLink]) -> String {
        links.compactMap { judged in
            judged.decidingFinding.map { finding in
                let host = judged.target.hosts.first ?? judged.target.scheme ?? "a relative link"
                return host + " (\(finding.phrase))"
            }
        }.joined(separator: "; ")
    }
}
