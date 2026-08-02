import SwiftUI

/// Choose the model every unrouted turn goes to.
struct ModelPickerView: View {
    @Environment(AppSettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var model: ModelPickerViewModel

    init(source: any ModelCatalogProviding) {
        _model = State(initialValue: ModelPickerViewModel(source: source))
    }

    var body: some View {
        @Bindable var model = model
        List {
            filters
            switch model.phase {
            case .loading:
                loading
            case let .failed(message):
                failure(message)
            case .loaded:
                results
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $model.filter.searchText, prompt: "Name or slug")
        .navigationTitle("Model")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("modelPickerList")
        .task { await model.load() }
    }

    private var filters: some View {
        @Bindable var model = model
        return Section {
            Toggle("Free only", isOn: $model.filter.freeOnly)
                .accessibilityIdentifier("modelFilterFree")
            Toggle("Tool calling", isOn: $model.filter.toolCapableOnly)
                .accessibilityIdentifier("modelFilterTools")
            Toggle("Vision", isOn: $model.filter.visionOnly)
                .accessibilityIdentifier("modelFilterVision")
            Toggle(
                "Large context (\(ModelFilter.largeContextThreshold / 1_000)K+)",
                isOn: $model.filter.largeContextOnly
            )
            .accessibilityIdentifier("modelFilterLargeContext")
        } header: {
            Text("Filters")
        }
    }

    private var loading: some View {
        Section {
            HStack(spacing: Theme.Spacing.snug) {
                ProgressView()
                Text("Loading the live catalogue…").font(Theme.Typeface.caption)
            }
            .accessibilityIdentifier("modelPickerLoading")
        }
    }

    /// A fetch that failed says so.
    ///
    /// The alternative — an empty list — would read as "OpenRouter has no models", which is both
    /// false and unactionable. This one names the error and offers the retry.
    private func failure(_ message: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                Text("Couldn't load the catalogue")
                    .font(Theme.Typeface.heading)
                Text(message)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { Task { await model.load() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier("modelPickerRetry")
            }
            .accessibilityIdentifier("modelPickerError")
        }
    }

    @ViewBuilder
    private var results: some View {
        if model.models.isEmpty {
            Section {
                Text(
                    model.filter.isNarrowed
                        ? "No model matches these filters."
                        : "The catalogue came back empty."
                )
                .font(Theme.Typeface.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("modelPickerEmpty")
            }
        } else {
            Section {
                ForEach(model.models) { entry in
                    ModelRow(model: entry, isSelected: entry.id == settings.defaultModelID) {
                        settings.defaultModelID = entry.id
                        dismiss()
                    }
                }
            } header: {
                Text("\(model.models.count) model(s), cheapest first")
            } footer: {
                exclusionNote
            }
        }
    }

    /// Why the router models are missing.
    @ViewBuilder
    private var exclusionNote: some View {
        if model.hiddenUnpricedCount > 0 {
            Text(
                "\(model.hiddenUnpricedCount) model(s) are hidden because OpenRouter prices them "
                    + "per request — they pick an upstream after you send, so no cost shown here "
                    + "could be true."
            )
            .accessibilityIdentifier("modelPickerExclusionNote")
        }
    }
}

/// One model, with everything the catalogue knows about it.
struct ModelRow: View {
    let model: OpenRouterModel
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: Theme.Spacing.snug) {
                details
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Selected")
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("modelRow-\(model.id)")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            Text(model.displayName)
                .font(Theme.Typeface.heading)
                .foregroundStyle(.primary)
            Text(model.id)
                .font(Theme.Typeface.metric)
                .foregroundStyle(.tertiary)
            HStack(spacing: Theme.Spacing.tight) {
                MetricChip(
                    ModelPresentation.priceText(for: model),
                    icon: "creditcard",
                    tint: model.price?.kind == .free ? Theme.Palette.success : .secondary
                )
            }
            HStack(spacing: Theme.Spacing.tight) {
                MetricChip(ModelPresentation.contextText(for: model), icon: "text.alignleft")
                ForEach(ModelPresentation.badges(for: model)) { badge in
                    MetricChip(badge.label, icon: badge.icon, tint: Theme.Palette.informational)
                }
            }
        }
    }
}
