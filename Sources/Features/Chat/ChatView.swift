import SwiftUI

/// The conversation.
struct ChatView: View {
    @Environment(ChatViewModel.self) private var model
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            thread
            if !model.followUps.isEmpty && !model.isSending {
                followUps
            }
            Divider()
            composer(draft: $model.draft)
        }
        .background(Theme.Palette.canvas)
        // The title is the conversation's own, once a turn has been named. Until then it is the
        // app's name rather than a spinner: a navigation bar that animates while an answer is
        // being read is a distraction for a caption nobody asked for.
        .navigationTitle(model.conversationTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The tappable suggestions.
    ///
    /// Hidden while a send is in flight rather than disabled, because a row of greyed-out chips
    /// under a streaming answer reads as something that has broken. They come back with the next
    /// set, which is a different set.
    private var followUps: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Theme.Spacing.tight) {
                // Indexed rather than keyed by the text itself: two identical suggestions are a
                // defect the repair loop is asked to fix, not one SwiftUI should silently merge.
                ForEach(Array(model.followUps.enumerated()), id: \.offset) { _, suggestion in
                    Button(suggestion) { model.sendFollowUp(suggestion) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .font(Theme.Typeface.caption)
                        .accessibilityIdentifier("followUpChip")
                }
            }
            .padding(.horizontal, Theme.Spacing.snug)
            .padding(.bottom, Theme.Spacing.tight)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("followUpChips")
    }

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.regular) {
                    if model.bubbles.isEmpty {
                        emptyState
                    }
                    ForEach(model.bubbles) { bubble in
                        if bubble.followsCompaction {
                            CompactionDivider()
                        }
                        BubbleRow(bubble: bubble)
                            .id(bubble.id)
                    }
                    if let refusal = model.activeRefusal {
                        RefusalBanner(refusal: refusal) { model.retryLast() }
                    }
                }
                .padding(Theme.Spacing.regular)
            }
            .onChange(of: model.bubbles.last?.text) { _, _ in
                guard let last = model.bubbles.last?.id else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.snug) {
            Text("Ask anything")
                .font(Theme.Typeface.heading)
            Text(
                environment.hasAPIKey
                    ? "Every message runs through the full pipeline — guardrails, routing, "
                        + "budget, retries, metering."
                    : "No OpenRouter key is configured yet. Add one in Settings to send messages."
            )
            .font(Theme.Typeface.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Theme.Spacing.section)
        .accessibilityIdentifier("chatEmptyState")
    }

    private func composer(draft: Binding<String>) -> some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.snug) {
            TextField("Message", text: draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .padding(Theme.Spacing.snug)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .fill(Theme.Palette.raised)
                )
                .accessibilityIdentifier("messageField")

            if model.isSending {
                Button(action: model.stop) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 30))
                }
                .accessibilityIdentifier("stopButton")
                .accessibilityLabel("Stop")
            } else {
                Button(action: model.send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                }
                .disabled(!model.canSend)
                .accessibilityIdentifier("sendButton")
                .accessibilityLabel("Send")
            }
        }
        .padding(Theme.Spacing.snug)
        .background(Theme.Palette.canvas)
    }
}

/// One message, plus everything the pipeline knows about it.
struct BubbleRow: View {
    let bubble: ChatBubble

    private var alignment: HorizontalAlignment {
        bubble.role == .user ? .trailing : .leading
    }

    private var frameAlignment: Alignment {
        bubble.role == .user ? .trailing : .leading
    }

    var body: some View {
        VStack(alignment: alignment, spacing: Theme.Spacing.tight) {
            content
            captions
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
    }

    private var content: some View {
        Group {
            if bubble.text.isEmpty && bubble.isPending {
                TypingIndicator()
            } else {
                // `LocalizedStringKey` gives inline markdown — bold, code spans, links — without a
                // parser. Models emit markdown constantly, and rendering it as literal asterisks
                // is the difference between a demo and something usable.
                Text(LocalizedStringKey(bubble.text))
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, Theme.Spacing.snug + 2)
        .padding(.vertical, Theme.Spacing.snug)
        .background(background)
        .foregroundStyle(bubble.role == .user ? Color.white : Color.primary)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.bubble))
        .frame(maxWidth: 320, alignment: frameAlignment)
        .accessibilityIdentifier(bubble.role == .user ? "userBubble" : "assistantBubble")
    }

    private var background: Color {
        switch bubble.delivery {
        case .refused: return Theme.Palette.refusal.opacity(0.15)
        case .failed: return Theme.Palette.failure.opacity(0.15)
        default:
            return bubble.role == .user ? Theme.Palette.userBubble : Theme.Palette.assistantBubble
        }
    }

    @ViewBuilder
    private var captions: some View {
        switch bubble.delivery {
        case let .refused(refusal):
            Text(refusal.headline)
                .font(Theme.Typeface.metric)
                .foregroundStyle(Theme.Palette.refusal)
        case let .failed(message):
            Text(message)
                .font(Theme.Typeface.metric)
                .foregroundStyle(Theme.Palette.failure)
        case .sending:
            Text("Sending…").font(Theme.Typeface.metric).foregroundStyle(.tertiary)
        case .streaming, .delivered:
            metricsRow
        }
    }

    /// What the tool round trip is doing, or did.
    ///
    /// Silence on the happy path is deliberate everywhere except while a tool is actually running:
    /// a chat that goes quiet for two round trips with no explanation reads as a hang, and a
    /// permission-style dialog for every read would train the user to dismiss it unread.
    @ViewBuilder
    private var toolChip: some View {
        switch bubble.toolState {
        case .idle:
            EmptyView()
        case let .running(tool):
            MetricChip(
                "Running \(tool)…",
                icon: "wrench.and.screwdriver",
                tint: Theme.Palette.refusal
            )
            .accessibilityIdentifier("toolRunningChip")
        case let .used(names):
            MetricChip(
                "Used \(names.joined(separator: ", "))",
                icon: "wrench.and.screwdriver",
                tint: Theme.Palette.success
            )
            .accessibilityIdentifier("toolUsedChip")
        case let .failed(tool, message):
            MetricChip(
                "\(tool) failed — \(message)",
                icon: "exclamationmark.triangle",
                tint: Theme.Palette.failure
            )
            .accessibilityIdentifier("toolFailedChip")
        }
    }

    @ViewBuilder
    private var metricsRow: some View {
        toolChip
        if !bubble.sources.isEmpty {
            HStack(spacing: Theme.Spacing.tight) {
                ForEach(bubble.sources) { source in
                    MetricChip(
                        "\(source.title) \(source.relevancePercent)%",
                        icon: "doc.text",
                        tint: Theme.Palette.success
                    )
                }
            }
        }
        if let fraction = bubble.groundedFraction, bubble.claimCount > 0 {
            let supported = Int((fraction * Double(bubble.claimCount)).rounded())
            MetricChip(
                "\(supported) of \(bubble.claimCount) verified",
                icon: supported == bubble.claimCount ? "checkmark.seal" : "exclamationmark.triangle",
                tint: supported == bubble.claimCount ? Theme.Palette.success : Theme.Palette.refusal
            )
            .accessibilityIdentifier("groundingChip")
        }
        if let metrics = bubble.metrics {
            HStack(spacing: Theme.Spacing.tight) {
                MetricChip(metrics.providerID, icon: "cpu")
                if metrics.promptTokens + metrics.completionTokens > 0 {
                    MetricChip("\(metrics.promptTokens) in / \(metrics.completionTokens) out")
                }
                if let cost = metrics.reportedCostUSD, cost > 0 {
                    MetricChip(String(format: "$%.6f", cost), icon: "creditcard")
                }
                if metrics.attempts > 1 {
                    MetricChip(
                        "Retried \(metrics.attempts)×",
                        icon: "arrow.clockwise",
                        tint: Theme.Palette.refusal
                    )
                }
            }
            .accessibilityIdentifier("bubbleMetrics")
        }
    }
}

/// The divider shown where compaction dropped earlier turns.
///
/// Silently shortening someone's conversation is the kind of thing that makes a chat app feel
/// haunted; saying so costs one row.
struct CompactionDivider: View {
    var body: some View {
        HStack(spacing: Theme.Spacing.tight) {
            Rectangle().frame(height: 1).foregroundStyle(Theme.Palette.hairline)
            Text("Earlier messages summarised to fit the context window")
                .font(Theme.Typeface.metric)
                .foregroundStyle(.tertiary)
                .fixedSize()
            Rectangle().frame(height: 1).foregroundStyle(Theme.Palette.hairline)
        }
        .accessibilityIdentifier("compactionDivider")
    }
}

struct TypingIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .frame(width: 6, height: 6)
                    .opacity(animating ? 1 : 0.3)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever()
                            .delay(Double(index) * 0.2),
                        value: animating
                    )
            }
        }
        .foregroundStyle(.secondary)
        .onAppear { animating = true }
        .accessibilityLabel("Assistant is typing")
    }
}
