import Foundation

/// One message as it is stored between launches.
///
/// Deliberately not `ChatBubble`. A bubble carries delivery state, tool chips, grounding fractions
/// and a refusal — all of which describe *one run* of a turn and mean nothing after a relaunch. A
/// conversation that restored "sending" bubbles would show a spinner for a turn nobody is waiting
/// on. Only what the user actually said and read is persisted.
struct StoredMessage: Codable, Identifiable, Sendable, Equatable {
    enum Role: String, Codable, Sendable { case user, assistant }

    let id: UUID
    var role: Role
    var text: String

    init(id: UUID = UUID(), role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

/// One thread in the chat list.
struct Conversation: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    var title: String
    /// The model this thread last used, so reopening it does not silently switch models.
    var modelID: String
    var messages: [StoredMessage]
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String = Conversation.untitled,
        modelID: String,
        messages: [StoredMessage] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.modelID = modelID
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static let untitled = "New chat"

    /// The second line of a row: the last thing said, whoever said it.
    ///
    /// The last message rather than the last *answer*, because a thread whose latest turn failed
    /// would otherwise preview an older reply and look like nothing had happened since.
    var preview: String {
        guard let last = messages.last else { return "No messages yet" }
        let flattened = last.text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flattened.isEmpty ? "No messages yet" : flattened
    }

    var isEmpty: Bool { messages.isEmpty }
}

/// Where conversations survive a relaunch, scoped to one profile.
protocol ConversationPersisting: Sendable {
    func loadConversations(profileID: UUID) -> Data?
    func saveConversations(_ data: Data, profileID: UUID)
}

struct UserDefaultsConversations: ConversationPersisting {
    /// Keyed per profile, which is what makes "each user has their own chats" true rather than a
    /// filter over one shared list that a bug could leak across.
    static func key(profileID: UUID) -> String { "conversations.v1.\(profileID.uuidString)" }

    nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadConversations(profileID: UUID) -> Data? {
        defaults.data(forKey: Self.key(profileID: profileID))
    }

    func saveConversations(_ data: Data, profileID: UUID) {
        defaults.set(data, forKey: Self.key(profileID: profileID))
    }
}

/// Conversations that vanish with the process.
final class InMemoryConversations: ConversationPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [UUID: Data] = [:]

    init() {}

    func loadConversations(profileID: UUID) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return stored[profileID]
    }

    func saveConversations(_ data: Data, profileID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        stored[profileID] = data
    }
}

/// The chat list, and the history behind each row.
///
/// Scoped to one profile at a time: `load(profileID:)` swaps the whole list rather than filtering,
/// so no in-memory state holds another profile's messages.
@MainActor
@Observable
final class ConversationStore {
    private(set) var conversations: [Conversation] = []
    private(set) var profileID: UUID

    private let persistence: any ConversationPersisting
    private let clock: @Sendable () -> Date

    init(
        profileID: UUID,
        persistence: any ConversationPersisting = UserDefaultsConversations(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.profileID = profileID
        self.persistence = persistence
        self.clock = clock
        load(profileID: profileID)
    }

    /// Switches to another profile's chats, dropping this one's from memory.
    func load(profileID: UUID) {
        self.profileID = profileID
        guard let data = persistence.loadConversations(profileID: profileID),
              let decoded = try? JSONDecoder().decode([Conversation].self, from: data) else {
            conversations = []
            return
        }
        conversations = decoded.sorted { $0.updatedAt > $1.updatedAt }
    }

    func conversation(_ id: UUID) -> Conversation? {
        conversations.first { $0.id == id }
    }

    /// Starts a thread and returns it, newest-first at the top of the list.
    @discardableResult
    func startConversation(modelID: String) -> Conversation {
        let conversation = Conversation(modelID: modelID, createdAt: clock(), updatedAt: clock())
        conversations.insert(conversation, at: 0)
        persist()
        return conversation
    }

    /// Replaces a thread's messages after a turn.
    ///
    /// `updatedAt` moves only when something actually changed, or opening a thread just to read it
    /// would reorder the list under the user's finger.
    func replaceMessages(_ messages: [StoredMessage], in id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }),
              conversations[index].messages != messages else { return }
        conversations[index].messages = messages
        conversations[index].updatedAt = clock()
        resort()
        persist()
    }

    func rename(_ id: UUID, to title: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, conversations[index].title != trimmed else { return }
        conversations[index].title = trimmed
        persist()
    }

    func setModel(_ modelID: String, for id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }),
              conversations[index].modelID != modelID else { return }
        conversations[index].modelID = modelID
        persist()
    }

    func delete(_ id: UUID) {
        guard conversations.contains(where: { $0.id == id }) else { return }
        conversations.removeAll { $0.id == id }
        persist()
    }

    func deleteAll() {
        guard !conversations.isEmpty else { return }
        conversations.removeAll()
        persist()
    }

    /// Drops threads nobody ever said anything in.
    ///
    /// Tapping "New chat" and backing out immediately is common, and each one would otherwise
    /// leave a permanent "New chat · No messages yet" row.
    func pruneEmpty(keeping keep: UUID? = nil) {
        let before = conversations.count
        conversations.removeAll { $0.isEmpty && $0.id != keep }
        guard conversations.count != before else { return }
        persist()
    }

    private func resort() {
        conversations.sort { $0.updatedAt > $1.updatedAt }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(conversations) else { return }
        persistence.saveConversations(data, profileID: profileID)
    }
}
