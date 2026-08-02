import AVFoundation
import SwiftUI

/// Reads a message out loud.
///
/// One synthesizer for the screen rather than one per bubble: `AVSpeechSynthesizer` keeps speaking
/// after the view that owns it goes away, so a per-bubble instance would leave a voice running
/// with nothing left to stop it. Speaking a second message stops the first, which is what a second
/// tap on a talking screen is asking for.
@MainActor
@Observable
final class SpeechReader {
    /// Which bubble is being read, so its button can show that it is the one talking.
    private(set) var speakingID: UUID?

    private let synthesizer = AVSpeechSynthesizer()

    /// Starts reading, or stops if this same message is already being read.
    func toggle(_ text: String, id: UUID) {
        guard speakingID != id else {
            stop()
            return
        }
        synthesizer.stopSpeaking(at: .immediate)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
        synthesizer.speak(utterance)
        speakingID = id
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        speakingID = nil
    }
}

/// What the row under a bubble can do. Closures rather than a view-model reference, so a snapshot
/// can render the row without standing up a conversation.
struct BubbleActions {
    var isSpeaking = false
    /// Edit and retry are only offered where they mean something — see `MessageActionsRow`.
    var canRevise = false
    var onCopy: () -> Void = {}
    var onEdit: () -> Void = {}
    var onRetry: () -> Void = {}
    var onSpeak: () -> Void = {}
    var onMore: () -> Void = {}
}

/// Copy, edit, retry, read aloud, more — under every message.
///
/// Icons rather than words: five labelled buttons do not fit under a bubble at any accessible text
/// size, and the row would wrap into something that looks broken. Each carries an accessibility
/// label, so nothing is lost to VoiceOver by dropping the visible text.
///
/// Edit and retry appear only on the user's own messages. Retrying an answer means resending the
/// question above it, so offering it on both would be two controls doing one thing.
struct MessageActionsRow: View {
    let actions: BubbleActions

    var body: some View {
        HStack(spacing: Theme.Spacing.snug) {
            button("doc.on.doc", "Copy", "copyMessage", actions.onCopy)
            if actions.canRevise {
                button("pencil", "Edit", "editMessage", actions.onEdit)
                button("arrow.clockwise", "Retry", "retryMessage", actions.onRetry)
            }
            button(
                actions.isSpeaking ? "speaker.wave.2.fill" : "speaker.wave.2",
                actions.isSpeaking ? "Stop reading" : "Read aloud",
                "speakMessage",
                actions.onSpeak
            )
            button("ellipsis", "More", "moreMessage", actions.onMore)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("messageActions")
    }

    private func button(
        _ symbol: String,
        _ label: String,
        _ identifier: String,
        _ action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                // A tappable area larger than the glyph. A 13pt icon is otherwise a 13pt target,
                // well under the 44pt the platform asks for.
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(label)
    }
}

/// Everything about one message that does not belong under it.
///
/// The sources, grounding, model, tokens, cost and retry count used to sit permanently beneath the
/// bubble, where they truncated to a row of ellipses at any real width — "opena…", "318 in /…",
/// "$0.00…". They are worth reading occasionally and worth seeing never, which is what a sheet is
/// for. The timestamp lives here for the same reason.
struct MessageDetailsSheet: View {
    let bubble: ChatBubble

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Message") {
                    LabeledContent(
                        "Sent",
                        value: bubble.createdAt.formatted(date: .abbreviated, time: .shortened)
                    )
                    .accessibilityIdentifier("detailTime")
                    LabeledContent("From", value: bubble.role == .user ? "You" : "Assistant")
                }

                if let metrics = bubble.metrics {
                    Section("This turn") {
                        LabeledContent("Model", value: metrics.providerID)
                            .accessibilityIdentifier("detailModel")
                        LabeledContent(
                            "Tokens",
                            value: "\(metrics.promptTokens) in / \(metrics.completionTokens) out"
                        )
                        if let cost = metrics.reportedCostUSD {
                            // Six places, matching how the app reports cost everywhere else: a
                            // turn costs a fraction of a cent and two places would read as $0.00.
                            LabeledContent("Cost", value: String(format: "$%.6f", cost))
                                .accessibilityIdentifier("detailCost")
                        }
                        if metrics.attempts > 1 {
                            LabeledContent("Attempts", value: "\(metrics.attempts)")
                        }
                    }
                }

                if !bubble.sources.isEmpty {
                    Section("Sources") {
                        ForEach(bubble.sources) { source in
                            LabeledContent(source.title, value: "\(source.relevancePercent)%")
                        }
                    }
                }

                if let fraction = bubble.groundedFraction, bubble.claimCount > 0 {
                    let supported = Int((fraction * Double(bubble.claimCount)).rounded())
                    Section("Grounding") {
                        LabeledContent(
                            "Claims supported",
                            value: "\(supported) of \(bubble.claimCount)"
                        )
                        .accessibilityIdentifier("detailGrounding")
                    }
                }
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .accessibilityIdentifier("messageDetailsSheet")
    }
}
