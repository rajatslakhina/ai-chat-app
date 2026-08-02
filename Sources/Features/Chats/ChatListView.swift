import SwiftUI

/// A round monogram for a profile.
///
/// Initials rather than a photo: a photo picker means a permission prompt, a privacy string and an
/// image store, none of which this app needs to prove it has profiles. Falls back to a glyph when
/// there is nothing to take initials from, because an empty circle reads as a broken image.
struct ProfileAvatar: View {
    let profile: UserProfile
    var diameter: CGFloat = 32

    var body: some View {
        ZStack {
            Circle().fill(profile.avatarColor.gradient)
            if profile.monogram.isEmpty {
                Image(systemName: "person.fill")
                    .foregroundStyle(.white)
                    .font(.system(size: diameter * 0.45))
            } else {
                Text(profile.monogram)
                    .font(.system(size: diameter * 0.4, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityIdentifier("profileAvatar")
        .accessibilityLabel("\(profile.displayName) profile")
    }
}

/// The chat list: every thread this profile has, newest first.
struct ChatListView: View {
    @Environment(ProfileStore.self) private var profiles
    @Environment(ConversationStore.self) private var conversations
    @Environment(AppSettingsStore.self) private var settings

    /// Opening a thread is a navigation, and starting one is a navigation to a thread that did not
    /// exist a moment ago. Both go through the same path so the chat screen has one entry point.
    @Binding var openConversationID: UUID?

    /// Re-read on every redraw rather than held, so a list left open across midnight regroups
    /// instead of insisting yesterday is still today.
    private var groups: [(title: String, items: [Conversation])] {
        DaySection.group(conversations.conversations, by: \.updatedAt)
    }

    var body: some View {
        List {
            if conversations.conversations.isEmpty {
                emptyState
            }
            ForEach(groups, id: \.title) { group in
                Section {
                    ForEach(group.items) { conversation in
                        Button {
                            openConversationID = conversation.id
                        } label: {
                            ChatListRow(conversation: conversation)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("chatRow-\(conversation.id.uuidString)")
                    }
                    .onDelete { delete(group.items, at: $0) }
                } header: {
                    Text(group.title)
                        .accessibilityIdentifier("chatSection-\(group.title)")
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Chats")
        .toolbar { toolbar }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            Text("No chats yet")
                .font(Theme.Typeface.heading)
            Text("Start one and it will be kept here, on this device, for this profile.")
                .font(Theme.Typeface.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, Theme.Spacing.snug)
        .accessibilityIdentifier("chatListEmpty")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            NavigationLink(value: AppDestination.profile) {
                ProfileAvatar(profile: profiles.active, diameter: 30)
            }
            .accessibilityIdentifier("profileButton")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: startChat) {
                Image(systemName: "square.and.pencil")
            }
            .accessibilityIdentifier("newChatButton")
            .accessibilityLabel("New chat")
        }
    }

    private func startChat() {
        // Threads nobody said anything in are dropped first. Tapping New chat and backing out is
        // common, and each one would otherwise leave a permanent "New chat · No messages yet" row.
        conversations.pruneEmpty()
        let started = conversations.startConversation(modelID: settings.defaultModelID)
        openConversationID = started.id
    }

    /// Offsets are relative to the section, so they are resolved against that section's own
    /// items. Indexing the flat list here would delete whatever happened to sit at that position
    /// in another day's group.
    private func delete(_ items: [Conversation], at offsets: IndexSet) {
        for index in offsets where items.indices.contains(index) {
            conversations.delete(items[index].id)
        }
    }
}

/// One row: what the thread is called, what was last said in it, and when.
struct ChatListRow: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.hair) {
            HStack {
                Text(conversation.title)
                    .font(Theme.Typeface.heading)
                    .lineLimit(1)
                Spacer()
                // "Now", then seconds, minutes, hours — and a clock time once a day has passed,
                // by which point the section header above already says which day.
                Text(RelativeTime.label(for: conversation.updatedAt))
                    .font(Theme.Typeface.metric)
                    .foregroundStyle(.tertiary)
            }
            Text(conversation.preview)
                .font(Theme.Typeface.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, Theme.Spacing.hair)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
