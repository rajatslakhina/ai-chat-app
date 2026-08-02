import Foundation
import Testing
@testable import AIChatApp

@MainActor
@Suite("Profiles")
struct ProfileStoreTests {
    @Test("a fresh install has exactly one profile, and it is the active one")
    func bootstraps() {
        let store = ProfileStore(persistence: InMemoryProfiles())
        #expect(store.profiles.count == 1)
        #expect(store.active.id == store.activeID)
        #expect(store.active.email == DemoAccount.email)
    }

    @Test("profiles survive a relaunch, and so does which one was active")
    func roundTrips() {
        let persistence = InMemoryProfiles()
        let first = ProfileStore(persistence: persistence)
        let added = first.addProfile(displayName: "Sam")

        let reopened = ProfileStore(persistence: persistence)
        #expect(reopened.profiles.count == 2)
        #expect(reopened.activeID == added.id, "adding a profile switches to it")
        #expect(reopened.active.displayName == "Sam")
    }

    @Test("an active id naming a profile that no longer exists is repaired on load")
    func repairsDanglingActiveID() {
        // Reachable in practice: a build that deleted a profile without rewriting the active id,
        // or a hand-edited defaults blob. Every scoped read would otherwise point at nothing.
        let blob = """
        {"profiles":[{"id":"\(UUID().uuidString)","displayName":"A","email":"",
        "avatarSeed":0,"createdAt":0}],"activeID":"\(UUID().uuidString)"}
        """
        let store = ProfileStore(persistence: InMemoryProfiles(seed: Data(blob.utf8)))
        #expect(store.activeID == store.profiles[0].id)
    }

    @Test("a blank name becomes a placeholder rather than an empty row")
    func blankNameIsReplaced() {
        let store = ProfileStore(persistence: InMemoryProfiles())
        let added = store.addProfile(displayName: "   ")
        #expect(added.displayName == "Untitled")

        var edited = added
        edited.displayName = ""
        store.update(edited)
        #expect(store.active.displayName == "Untitled")
    }

    @Test("editing a profile saves the name, the email and the colour")
    func edits() {
        let store = ProfileStore(persistence: InMemoryProfiles())
        var profile = store.active
        profile.displayName = "Rajat Lakhina"
        profile.email = "  rajat@example.test "
        profile.avatarSeed = 3
        store.update(profile)

        #expect(store.active.displayName == "Rajat Lakhina")
        #expect(store.active.email == "rajat@example.test", "whitespace is trimmed")
        #expect(store.active.monogram == "RL")
        #expect(store.active.avatarSeed == 3)
    }

    @Test("deleting the last profile re-bootstraps rather than leaving none")
    func deletingTheLastOneRebootstraps() {
        let store = ProfileStore(persistence: InMemoryProfiles())
        store.delete(store.activeID)
        #expect(store.profiles.count == 1)
        #expect(store.profiles.contains { $0.id == store.activeID })
    }

    @Test("a seed outside the palette still resolves to a colour")
    func avatarSeedIsBounded() {
        // A palette that later shrinks, or a hand-edited seed, must not index out of bounds.
        _ = UserProfile(displayName: "X", avatarSeed: 9_999).avatarColor
        _ = UserProfile(displayName: "Y", avatarSeed: -7).avatarColor
    }

    @Test("a nameless profile has no monogram, so the avatar can fall back to a glyph")
    func emptyMonogram() {
        #expect(UserProfile(displayName: "").monogram.isEmpty)
        #expect(UserProfile(displayName: "Ada Lovelace King").monogram == "AL", "at most two")
    }
}

@MainActor
@Suite("Chat history")
struct ConversationStoreTests {
    private func makeStore(
        _ persistence: InMemoryConversations = InMemoryConversations(),
        profile: UUID = UUID()
    ) -> ConversationStore {
        ConversationStore(profileID: profile, persistence: persistence)
    }

    @Test("a new thread goes to the top and is empty")
    func starts() {
        let store = makeStore()
        let started = store.startConversation(modelID: "openai/gpt-4o")
        #expect(store.conversations.first?.id == started.id)
        #expect(started.isEmpty)
        #expect(started.title == Conversation.untitled)
        #expect(started.preview == "No messages yet")
    }

    @Test("messages survive a relaunch")
    func roundTrips() {
        let persistence = InMemoryConversations()
        let profile = UUID()
        let first = makeStore(persistence, profile: profile)
        let started = first.startConversation(modelID: "openai/gpt-4o")
        first.replaceMessages([StoredMessage(role: .user, text: "hello")], in: started.id)

        let reopened = makeStore(persistence, profile: profile)
        #expect(reopened.conversations.count == 1)
        #expect(reopened.conversations.first?.messages.first?.text == "hello")
        #expect(reopened.conversations.first?.preview == "hello")
    }

    @Test("one profile cannot see another's chats")
    func scopedPerProfile() {
        // The property that makes "each user has their own chats" true. A shared list with a
        // filter would leak the moment the filter was forgotten.
        let persistence = InMemoryConversations()
        let mine = UUID()
        let first = makeStore(persistence, profile: mine)
        first.startConversation(modelID: "openai/gpt-4o")

        let second = makeStore(persistence, profile: UUID())
        #expect(second.conversations.isEmpty)

        second.load(profileID: mine)
        #expect(second.conversations.count == 1)
    }

    @Test("saying something reorders the list; merely opening a thread does not")
    func ordering() {
        nonisolated(unsafe) var now = Date(timeIntervalSince1970: 0)
        let store = ConversationStore(
            profileID: UUID(),
            persistence: InMemoryConversations(),
            clock: { now }
        )
        let older = store.startConversation(modelID: "m")
        now = now.addingTimeInterval(60)
        let newer = store.startConversation(modelID: "m")
        #expect(store.conversations.first?.id == newer.id)

        now = now.addingTimeInterval(60)
        store.replaceMessages([StoredMessage(role: .user, text: "hi")], in: older.id)
        #expect(store.conversations.first?.id == older.id, "the thread just used comes first")

        // Re-writing identical messages must not move it: opening a thread to read it would
        // otherwise reorder the list under the user's finger.
        let orderBefore = store.conversations.map(\.id)
        store.replaceMessages([StoredMessage(role: .user, text: "hi")], in: older.id)
        #expect(store.conversations.map(\.id) == orderBefore)
    }

    @Test("renaming, re-modelling and deleting all stick")
    func mutations() {
        let store = makeStore()
        let started = store.startConversation(modelID: "openai/gpt-4o")

        store.rename(started.id, to: "  Budgets  ")
        #expect(store.conversation(started.id)?.title == "Budgets")

        store.rename(started.id, to: "   ")
        #expect(store.conversation(started.id)?.title == "Budgets", "a blank title is ignored")

        store.setModel("anthropic/claude", for: started.id)
        #expect(store.conversation(started.id)?.modelID == "anthropic/claude")

        store.delete(started.id)
        #expect(store.conversations.isEmpty)
    }

    @Test("empty threads are pruned, except the one being opened")
    func prunes() {
        let store = makeStore()
        let abandoned = store.startConversation(modelID: "m")
        let keeping = store.startConversation(modelID: "m")
        store.pruneEmpty(keeping: keeping.id)

        #expect(store.conversation(abandoned.id) == nil)
        #expect(store.conversation(keeping.id) != nil)
    }

    @Test("a thread with messages is never pruned")
    func neverPrunesRealThreads() {
        let store = makeStore()
        let real = store.startConversation(modelID: "m")
        store.replaceMessages([StoredMessage(role: .user, text: "hi")], in: real.id)
        store.pruneEmpty()
        #expect(store.conversation(real.id) != nil)
    }

    @Test("deleting everything leaves an empty list rather than a stale one")
    func deletesAll() {
        let store = makeStore()
        store.startConversation(modelID: "m")
        store.startConversation(modelID: "m")
        store.deleteAll()
        #expect(store.conversations.isEmpty)
    }
}

@MainActor
@Suite("Settings, scoped per profile")
struct ScopedSettingsTests {
    @Test("an existing install's settings are inherited once, not shared forever")
    func migratesLegacyBlobOnce() throws {
        // The upgrade path. Without it, adding profiles resets everyone's model, budget and
        // temperature — and the fallback in `init` would make that look like a fresh install.
        let suite = try #require(UserDefaults(suiteName: "scoped-settings-\(UUID().uuidString)"))
        let legacy = AppSettingsStore(persistence: UserDefaultsSettings(defaults: suite))
        legacy.budgetCeilingUSD = 12

        let profile = UUID()
        let scoped = AppSettingsStore(
            persistence: UserDefaultsSettings(defaults: suite, profileID: profile)
        )
        #expect(scoped.budgetCeilingUSD == 12, "the pre-profile settings carry over")

        // Once the scoped key exists the legacy one is never consulted again for that profile,
        // so an edit cannot be undone by the ancestor blob on the next launch.
        scoped.budgetCeilingUSD = 3
        let reopened = AppSettingsStore(
            persistence: UserDefaultsSettings(defaults: suite, profileID: profile)
        )
        #expect(reopened.budgetCeilingUSD == 3, "an edited profile keeps its own")
    }

    @Test("switching profile replaces the whole snapshot rather than merging it")
    func switchingReplaces() {
        let store = AppSettingsStore(persistence: InMemorySettings())
        store.budgetCeilingUSD = 99
        store.reload(persistence: InMemorySettings())
        #expect(store.budgetCeilingUSD == nil, "another person's ceiling must not carry over")
    }
}
