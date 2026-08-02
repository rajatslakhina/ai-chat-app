import SwiftUI

/// What OpenRouter says this key is allowed to spend.
struct KeyStatusSection: View {
    let source: any ModelCatalogProviding
    @State private var phase: Phase = .loading

    enum Phase: Equatable {
        case loading
        case loaded(OpenRouterKeyStatus)
        case failed(String)
    }

    var body: some View {
        Section {
            switch phase {
            case .loading:
                HStack(spacing: Theme.Spacing.snug) {
                    ProgressView()
                    Text("Checking the key…").font(Theme.Typeface.caption)
                }
                .accessibilityIdentifier("keyStatusLoading")
            case let .loaded(status):
                rows(status)
            case let .failed(message):
                Text(message)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.failure)
                    .accessibilityIdentifier("keyStatusError")
            }
        } header: {
            Text("Credit")
        } footer: {
            Text(
                "Read from GET /api/v1/key. A key with no limit reports as unlimited — that is a "
                    + "different state from having nothing left, and this screen never conflates "
                    + "the two."
            )
        }
        .task { await load() }
    }

    @ViewBuilder
    private func rows(_ status: OpenRouterKeyStatus) -> some View {
        if let label = status.label {
            LabeledContent("Key", value: label)
                .accessibilityIdentifier("keyStatusLabel")
        }
        LabeledContent("Used", value: String(format: "$%.4f", status.usage ?? 0))
            .accessibilityIdentifier("keyStatusUsage")
        // `remainingDescription` owns the null-limit rule. Re-deriving it here would be the second
        // place that decides what an absent limit means, and one of the two would eventually be
        // wrong.
        LabeledContent("Remaining", value: status.remainingDescription)
            .accessibilityIdentifier("keyStatusRemaining")
        LabeledContent("Tier", value: (status.isFreeTier ?? false) ? "Free" : "Paid")
            .accessibilityIdentifier("keyStatusTier")
        if status.isExhausted {
            Text("This key has reached its limit. Add credit on openrouter.ai to keep sending.")
                .font(Theme.Typeface.caption)
                .foregroundStyle(Theme.Palette.refusal)
                .accessibilityIdentifier("keyStatusExhausted")
        }
    }

    private func load() async {
        do {
            phase = .loaded(try await source.fetchKeyStatus())
        } catch {
            phase = .failed("Couldn't read the key's status: \(error)")
        }
    }
}

/// The monthly spend ceiling, and what has gone against it.
struct BudgetSection: View {
    @Environment(AppSettingsStore.self) private var settings
    @State private var draft = ""

    var body: some View {
        @Bindable var settings = settings
        return Section {
            Toggle("Limit monthly spend", isOn: limited)
                .accessibilityIdentifier("budgetLimitToggle")
            if !settings.budget.isUnlimited {
                ceilingField
            }
            LabeledContent("Ceiling", value: settings.budget.ceilingText)
                .accessibilityIdentifier("budgetCeiling")
            LabeledContent("Spent in \(settings.budget.month)", value: settings.budget.spentText)
                .accessibilityIdentifier("budgetSpent")
            LabeledContent("Remaining", value: settings.budget.remainingText)
                .accessibilityIdentifier("budgetRemaining")
        } header: {
            Text("Budget")
        } footer: {
            Text(
                "QuotaGovernorKit holds an estimate before each turn and settles it afterwards, "
                    + "so the refusal arrives before the money does. The running total is kept by "
                    + "the app rather than the governor, whose ledger is in memory — otherwise "
                    + "relaunching would hand you the month's allowance again. A new ceiling "
                    + "takes effect on your next message, never mid-turn."
            )
        }
    }

    private var ceilingField: some View {
        HStack {
            TextField("Dollars", text: $draft)
                .keyboardType(.decimalPad)
                .accessibilityIdentifier("budgetCeilingField")
            Button("Set", action: commit)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(Double(draft) == nil)
                .accessibilityIdentifier("budgetCeilingApply")
        }
    }

    /// Turning the limit off clears the ceiling; turning it on seeds a real, small one.
    ///
    /// Seeding rather than starting at zero is deliberate: a zero ceiling refuses the very next
    /// message, and a toggle that instantly breaks the app teaches the user that the budget layer
    /// is something to leave alone.
    private var limited: Binding<Bool> {
        Binding(
            get: { !settings.budget.isUnlimited },
            set: { isOn in
                settings.budgetCeilingUSD = isOn ? (Double(draft) ?? 5) : nil
                if isOn && draft.isEmpty { draft = "5" }
            }
        )
    }

    private func commit() {
        guard let value = Double(draft), value.isFinite else { return }
        settings.budgetCeilingUSD = max(0, value)
    }
}

/// Generation parameters.
struct GenerationSection: View {
    @Environment(AppSettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        return Section {
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                LabeledContent(
                    "Temperature",
                    value: String(format: "%.2f", settings.temperature)
                )
                .accessibilityIdentifier("temperatureValue")
                Slider(
                    value: $settings.temperature,
                    in: TurnSettings.temperatureRange,
                    step: 0.05
                )
                .accessibilityIdentifier("temperatureSlider")
                .accessibilityLabel("Temperature")
            }
        } header: {
            Text("Generation")
        } footer: {
            Text(
                "Kept inside 0–2. ProviderGatewayKit enforces that range with a precondition, "
                    + "which traps in a release build rather than rejecting the request, so the "
                    + "value is clamped before it is stored — not on the way out."
            )
        }
    }
}

/// The pre-model stages that can be switched off.
struct PipelineSection: View {
    @Environment(AppSettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        return Section {
            Toggle("Semantic routing", isOn: $settings.routingEnabled)
                .accessibilityIdentifier("routingToggle")
            Toggle("Response cache", isOn: $settings.cacheEnabled)
                .accessibilityIdentifier("cacheToggle")
            Toggle("Memory recall", isOn: $settings.memoryEnabled)
                .accessibilityIdentifier("memoryToggle")
            Toggle("Retrieval", isOn: $settings.retrievalEnabled)
                .accessibilityIdentifier("retrievalToggle")
            Toggle("Ask before running tools", isOn: $settings.toolApprovalRequired)
                .accessibilityIdentifier("toolApprovalToggle")
        } header: {
            Text("Pipeline")
        } footer: {
            Text(
                "A stage switched off here records as skipped rather than vanishing, so "
                    + "Diagnostics still shows it and says why it did not run. Asking before "
                    + "running tools stops the turn and shows you the exact call — the tool, the "
                    + "arguments, and where those arguments came from — before anything runs."
            )
        }
    }
}
