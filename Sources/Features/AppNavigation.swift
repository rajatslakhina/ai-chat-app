import SwiftUI

/// The screens reachable from the chat.
///
/// Named `AppDestination` rather than `Route`, which is the conventional SwiftUI name for exactly
/// this enum: `SemanticRouterKit` already exports a public `Route`, and both would be in scope in
/// every file that imports it. Two same-named types in one file is a compiler error with a
/// confusing message; renaming ours is a one-word decision that avoids it everywhere.
enum AppDestination: Hashable {
    case models
    case settings
    case diagnostics
}

/// The signed-in shell: the conversation, and the way to everything else.
struct ChatScaffold: View {
    @Environment(AuthStore.self) private var auth
    let composition: Composition
    let model: ChatViewModel

    var body: some View {
        NavigationStack {
            ChatView()
                .toolbar { toolbar }
                .navigationDestination(for: AppDestination.self, destination: destination)
        }
        .environment(model)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            NavigationLink(value: AppDestination.diagnostics) {
                Image(systemName: "waveform.path.ecg")
            }
            .accessibilityIdentifier("diagnosticsButton")
            .accessibilityLabel("Diagnostics")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            NavigationLink(value: AppDestination.models) {
                Image(systemName: "cpu")
            }
            .accessibilityIdentifier("modelPickerButton")
            .accessibilityLabel("Model")

            NavigationLink(value: AppDestination.settings) {
                Image(systemName: "gearshape")
            }
            .accessibilityIdentifier("settingsButton")
            .accessibilityLabel("Settings")

            Button("Sign out", role: .destructive, action: auth.signOut)
                .accessibilityIdentifier("signOutButton")
        }
    }

    @ViewBuilder
    private func destination(_ destination: AppDestination) -> some View {
        switch destination {
        case .models:
            ModelPickerView(source: composition.catalog)
        case .settings:
            SettingsView(catalog: composition.catalog)
        case .diagnostics:
            DiagnosticsView()
        }
    }
}
