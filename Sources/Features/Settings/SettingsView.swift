import SwiftUI

/// Everything the user can change, and the truth about what is currently set.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettingsStore.self) private var settings
    let catalog: any ModelCatalogProviding

    var body: some View {
        List {
            APIKeySection()
            KeyStatusSection(source: catalog)
            modelSection
            BudgetSection()
            GenerationSection()
            PipelineSection()
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settingsList")
    }

    private var modelSection: some View {
        Section {
            NavigationLink(value: AppDestination.models) {
                LabeledContent("Default model", value: settings.defaultModelID)
                    .accessibilityIdentifier("defaultModelRow")
            }
            .accessibilityIdentifier("defaultModelLink")
        } header: {
            Text("Model")
        } footer: {
            Text(
                "Used for every turn the semantic router does not claim. Routed turns go to the "
                    + "model the matching route names."
            )
        }
    }
}

/// The key itself: what is set, where it came from, and how to change it.
struct APIKeySection: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var draft = ""
    @State private var failure: String?

    var body: some View {
        Section {
            current
            SecureField("sk-or-v1-…", text: $draft)
                .textContentType(.password)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("apiKeyField")
            Button(environment.hasAPIKey ? "Replace key" : "Save key", action: save)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("apiKeySaveButton")
            if environment.hasAPIKey {
                Button("Delete key", role: .destructive, action: delete)
                    .accessibilityIdentifier("apiKeyDeleteButton")
            }
            if let failure {
                Text(failure)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.failure)
                    .accessibilityIdentifier("apiKeyError")
            }
        } header: {
            Text("OpenRouter key")
        } footer: {
            Text(environment.secretOrigin.keyManagementNote)
        }
    }

    private var current: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.hair) {
            Text(environment.maskedAPIKey ?? "No key set")
                .font(Theme.Typeface.metric)
                .accessibilityIdentifier("apiKeyMasked")
            // Where the key came from is not trivia. A build-supplied key and one typed on this
            // device behave identically at the network layer and differently everywhere else —
            // only one of them explains why a TestFlight build works and a fresh clone does not.
            Text(environment.secretOrigin.settingsDescription)
                .font(Theme.Typeface.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("apiKeyOrigin")
        }
    }

    private func save() {
        apply(draft)
    }

    private func delete() {
        // An empty string is what `AppSecrets` treats as a removal; it never stores a blank.
        apply("")
    }

    private func apply(_ value: String) {
        failure = nil
        do {
            try environment.updateAPIKey(value)
            draft = ""
        } catch {
            failure = "Couldn't write to the Keychain: \(error)"
        }
    }
}
