import SwiftUI

/// The screens reachable from the chat list and the chat.
///
/// Named `AppDestination` rather than `Route`, which is the conventional SwiftUI name for exactly
/// this enum: `SemanticRouterKit` already exports a public `Route`, and both would be in scope in
/// every file that imports it. Two same-named types in one file is a compiler error with a
/// confusing message; renaming ours is a one-word decision that avoids it everywhere.
enum AppDestination: Hashable {
    case models
    case settings
    case diagnostics
    case profile
}

/// The signed-in shell: the list of chats, and the way to everything else.
///
/// The list is the root rather than a conversation. A chat app that opens straight into a thread
/// has to invent which thread that is, and every answer to that is wrong the first time someone
/// wanted a different one.
struct ChatScaffold: View {
    @Environment(ConversationStore.self) private var conversations
    let composition: Composition

    @State private var openConversationID: UUID?
    /// Owned here rather than inside `ConversationScreen`, and injected on the whole stack.
    ///
    /// `DiagnosticsView` reads the model from the environment, and a pushed destination only sees
    /// what the view that *registered* it could see. Building the model one level deeper compiled
    /// perfectly and then trapped on the environment lookup the moment Diagnostics opened.
    @State private var model: ChatViewModel?

    var body: some View {
        Group {
            if let model {
                NavigationStack {
                    ChatListView(openConversationID: opening)
                        .navigationDestination(item: opening) { id in
                            ConversationScreen(conversationID: id)
                        }
                        .navigationDestination(for: AppDestination.self, destination: destination)
                }
                .environment(model)
            } else {
                ProgressView()
            }
        }
        .task { seed() }
    }

    /// Opens a thread, building its model *before* the navigation rather than after.
    ///
    /// The model is injected on the stack, so replacing it is a change to the stack's environment.
    /// Doing that while a push is in flight re-identifies the stack mid-transition and the pushed
    /// screen comes up against a view that is being rebuilt underneath it. Setting the model first
    /// and the destination second means the environment is already correct when the push happens.
    private var opening: Binding<UUID?> {
        Binding(
            get: { openConversationID },
            set: { id in
                if let id { build(id) }
                openConversationID = id
            }
        )
    }

    /// Puts a model in the environment before anything can read one.
    ///
    /// Built once into `@State`, never computed in `body`. A `model ?? placeholder` expression
    /// looks equivalent and is not: it constructs a fresh `@Observable` on every render, and
    /// injecting a new object into the environment invalidates the view that just built it, so the
    /// screen never settles. The symptom was Diagnostics rendering nothing at all.
    @MainActor
    private func seed() {
        guard model == nil else { return }
        model = composition.makeChatViewModel(
            conversation: Conversation(modelID: ""),
            onPersist: { _, _ in }
        )
    }

    @MainActor
    private func build(_ id: UUID) {
        guard let conversation = conversations.conversation(id) else { return }
        model = composition.makeChatViewModel(
            conversation: conversation,
            onPersist: { messages, title in
                conversations.replaceMessages(messages, in: conversation.id)
                // The model names the thread once it has something to name it from, and the list
                // shows that name — so it has to travel back rather than live only in the bar.
                guard title != ChatViewModel.untitled else { return }
                conversations.rename(conversation.id, to: title)
            }
        )
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
        case .profile:
            ProfileView()
        }
    }
}

/// One conversation: the chat, and the screens reachable from it.
///
/// The view model comes from the environment rather than being built here, because the pushed
/// destinations need it too and only the stack can give it to them.
struct ConversationScreen: View {
    let conversationID: UUID

    @Environment(ConversationStore.self) private var conversations
    @Environment(AppSettingsStore.self) private var settings

    var body: some View {
        ChatView()
            .toolbar { toolbar }
            // The picker writes the app-wide default; a thread also remembers what it was last
            // answered with, so reopening an old chat does not silently answer it on a new model.
            .onChange(of: settings.defaultModelID) { _, newValue in
                conversations.setModel(newValue, for: conversationID)
            }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            NavigationLink(value: AppDestination.models) {
                Image(systemName: "cpu")
            }
            .accessibilityIdentifier("modelPickerButton")
            .accessibilityLabel("Model")

            NavigationLink(value: AppDestination.diagnostics) {
                Image(systemName: "waveform.path.ecg")
            }
            .accessibilityIdentifier("diagnosticsButton")
            .accessibilityLabel("Diagnostics")

            NavigationLink(value: AppDestination.settings) {
                Image(systemName: "gearshape")
            }
            .accessibilityIdentifier("settingsButton")
            .accessibilityLabel("Settings")
        }
    }
}
