import Foundation
import ProviderGatewayKit
import Testing
@testable import AIChatApp

@Suite("Reasoning effort")
struct ReasoningEffortTests {
    @Test("the levels read fastest to smartest, which is the order the picker shows")
    func ordering() {
        #expect(ReasoningEffort.allCases == [.low, .medium, .high, .extra])
        #expect(ReasoningEffort.fallback == .medium)
    }

    @Test("extra is xhigh on the wire; everything else matches its own name")
    func wireValues() {
        // OpenRouter's vocabulary, not this app's. Getting it wrong fails silently: an unknown
        // effort is ignored upstream, so the control would appear to work and change nothing.
        #expect(ReasoningEffort.extra.wireValue == "xhigh")
        #expect(ReasoningEffort.high.wireValue == "high")
        #expect(ReasoningEffort.medium.wireValue == "medium")
        #expect(ReasoningEffort.low.wireValue == "low")
    }

    @Test("every level says what it costs, not just what it is called")
    func labels() {
        for level in ReasoningEffort.allCases {
            #expect(!level.title.isEmpty)
            #expect(!level.detail.isEmpty)
            #expect(!level.symbol.isEmpty)
        }
    }

    @Test("the box hands back whatever was last set")
    func box() {
        let box = ReasoningEffortBox()
        #expect(box.current == nil, "nothing chosen means nothing is sent")
        box.set(.extra)
        #expect(box.current == .extra)
        box.set(nil)
        #expect(box.current == nil)
    }

    // MARK: - What actually goes on the wire

    private func body(effort: ReasoningEffort?) throws -> [String: Any] {
        let request = OpenRouterChatRequest(
            model: "openai/gpt-4o",
            messages: [],
            temperature: 0.7,
            maxTokens: 1_024,
            stream: false,
            tools: nil,
            usage: .init(include: true),
            reasoning: effort.map { .init(effort: $0.wireValue) }
        )
        let data = try JSONEncoder().encode(request)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("a chosen effort reaches the request body under OpenRouter's own key")
    func reasoningIsSent() throws {
        let json = try body(effort: .extra)
        let reasoning = try #require(json["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == "xhigh")
    }

    @Test("no effort omits the key entirely rather than sending null")
    func reasoningIsOmitted() throws {
        // Not the same thing to OpenRouter, and the request type documents that. A `null` would be
        // the app asserting something about reasoning for a model that may not reason at all.
        let json = try body(effort: nil)
        #expect(json["reasoning"] == nil)
        #expect(json.keys.contains("model"), "the rest of the body is unaffected")
    }
}

@MainActor
@Suite("Effort on a conversation")
struct ConversationEffortTests {
    private func makeStore() -> ConversationStore {
        ConversationStore(profileID: UUID(), persistence: InMemoryConversations())
    }

    @Test("a thread that never chose an effort uses the default rather than none")
    func defaults() {
        let started = makeStore().startConversation(modelID: "openai/gpt-4o")
        #expect(started.effort == nil, "nothing is written until the user picks")
        #expect(started.resolvedEffort == .medium)
    }

    @Test("choosing an effort sticks, and survives a relaunch")
    func persists() {
        let persistence = InMemoryConversations()
        let profile = UUID()
        let first = ConversationStore(profileID: profile, persistence: persistence)
        let started = first.startConversation(modelID: "openai/gpt-4o")
        first.setEffort(.extra, for: started.id)

        let reopened = ConversationStore(profileID: profile, persistence: persistence)
        #expect(reopened.conversation(started.id)?.effort == .extra)
        #expect(reopened.conversation(started.id)?.resolvedEffort == .extra)
    }

    @Test("two threads can disagree, which is the whole point of it being per-chat")
    func perConversation() {
        let store = makeStore()
        let quick = store.startConversation(modelID: "m")
        let careful = store.startConversation(modelID: "m")
        store.setEffort(.low, for: quick.id)
        store.setEffort(.extra, for: careful.id)

        #expect(store.conversation(quick.id)?.resolvedEffort == .low)
        #expect(store.conversation(careful.id)?.resolvedEffort == .extra)
    }

    @Test("a thread written before efforts existed still decodes")
    func decodesOlderThreads() {
        // The upgrade path. A non-optional field here would make every existing thread fail to
        // decode, and the store's fallback would present that as "no chats yet".
        let older = """
        [{"id":"\(UUID().uuidString)","title":"Old","modelID":"openai/gpt-4o",
        "messages":[],"createdAt":0,"updatedAt":0}]
        """
        let persistence = InMemoryConversations()
        let profile = UUID()
        persistence.saveConversations(Data(older.utf8), profileID: profile)

        let store = ConversationStore(profileID: profile, persistence: persistence)
        #expect(store.conversations.count == 1, "an older thread must not vanish")
        #expect(store.conversations.first?.resolvedEffort == .medium)
    }
}
