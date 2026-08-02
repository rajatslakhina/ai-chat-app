import Foundation
import RetrievalKit
import SpotlightRAG

/// The passages the app can retrieve over, and the lexical half of how it finds them.
///
/// The dense retriever was wired from the start but never had a corpus — `retrieve` was called and
/// nothing ever indexed, so the stage recorded "no indexed passages matched" on every single turn
/// and looked like a working feature. This gives it something to find, and gives it a second way
/// of finding it.
///
/// Two rankings rather than one because they fail differently. Embeddings match paraphrase and
/// miss exact tokens — a model identifier, a price, a setting name — and a lexical index does the
/// reverse. Fusing them is not belt-and-braces; it is the only way "what does gpt-4o cost" and
/// "how much am I paying" both land on the same passage.
enum AppKnowledge {
    /// A fixed instant rather than `Date()`: `IndexableDocument.digest` includes `updatedAt`, so a
    /// clock reading would give the same document a different digest on every launch and defeat
    /// the reconciler's whole purpose.
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    static let scope = OwnerScope("app")

    /// What this app can actually answer about itself. Deliberately small and specific: a corpus
    /// of vague marketing sentences retrieves well and helps nobody.
    static let documents: [IndexableDocument] = [
        IndexableDocument(
            id: DocumentID("models"),
            title: "Choosing a model",
            body: """
            The model picker lists every OpenRouter model with published per-token pricing. \
            Models whose price is the -1 sentinel — openrouter/auto, auto-beta, fusion, \
            pareto-code and bodybuilder — are excluded, because a negative price subtracted from \
            a running total silently reduces it. Tool calling requires both tools and tool_choice \
            in a model's supported_parameters.
            """,
            keywords: ["model", "gpt-4o", "picker", "pricing", "tools"],
            updatedAt: epoch,
            ownerScope: scope
        ),
        IndexableDocument(
            id: DocumentID("budget"),
            title: "Budgets and spend",
            body: """
            Settings can cap what the account spends inside one calendar month. The ceiling is \
            held by QuotaGovernorKit, which reserves an estimated cost before the turn and settles \
            the real cost afterwards. An empty ceiling means unlimited, which is not the same as \
            zero — a zero ceiling refuses the very first message. Spend is stored in microcents.
            """,
            keywords: ["budget", "cost", "spend", "ceiling", "money", "credit"],
            updatedAt: epoch,
            ownerScope: scope
        ),
        IndexableDocument(
            id: DocumentID("tools"),
            title: "Tools and approval",
            body: """
            The assistant can call a calculator and a clock. Every call is authorized before it is \
            dispatched, never after, because a registry that has already run a handler cannot be \
            un-run by a policy decision. Turning on "Ask before running tools" stops the turn and \
            shows the exact call — the tool, the arguments, and where those arguments came from — \
            so a call whose arguments came out of a retrieved document can be refused.
            """,
            keywords: ["tool", "calculator", "clock", "approval", "authority", "permission"],
            updatedAt: epoch,
            ownerScope: scope
        ),
        IndexableDocument(
            id: DocumentID("privacy"),
            title: "What leaves the device",
            body: """
            Prompts are screened by GuardrailKit before they are sent and answers are screened \
            again before they are shown, so a redaction changes what the user sees rather than \
            only what a log records. Only reviewed text is cached. The API key lives in the \
            Keychain and is never written to the repository.
            """,
            keywords: ["privacy", "pii", "redaction", "guardrail", "keychain", "key"],
            updatedAt: epoch,
            ownerScope: scope
        )
    ]

    /// The same passages in the dense retriever's vocabulary, so both halves see one corpus.
    ///
    /// If these ever diverged, fusion would be combining rankings over different document sets and
    /// the reciprocal-rank arithmetic would still produce a confident-looking order.
    static var retrievalDocuments: [RetrievalKit.Document] {
        documents.map {
            RetrievalKit.Document(
                id: $0.id.rawValue,
                text: "\($0.title). \($0.body)",
                metadata: ["title": $0.title]
            )
        }
    }

    static func title(for id: String) -> String? {
        documents.first { $0.id.rawValue == id }?.title
    }

    static func body(for id: String) -> String? {
        documents.first { $0.id.rawValue == id }?.body
    }
}

/// The lexical index, wrapped so the pipeline never handles `SpotlightRAG`'s query type directly.
actor LexicalIndex {
    private let backend: any SearchIndexBackend
    private let scope: OwnerScope

    init(
        backend: any SearchIndexBackend = InMemorySearchIndex(),
        scope: OwnerScope = AppKnowledge.scope
    ) {
        self.backend = backend
        self.scope = scope
    }

    /// Loads the corpus. Idempotent — `upsert` is keyed by document id, so re-seeding an unchanged
    /// corpus replaces rather than duplicates.
    func seed(_ documents: [IndexableDocument] = AppKnowledge.documents) async throws {
        try await backend.upsert(documents.map(IndexedPayload.init(document:)))
    }

    /// The lexical ranking for a query, most relevant first.
    ///
    /// `allowedScopes` is not decoration even with one scope: `IndexQuery` refuses to return a
    /// document outside the scopes it was asked for, which is the mechanism that would keep one
    /// user's passages out of another's results the day this stops being a single-user app.
    func ranking(for text: String, limit: Int) async throws -> [IndexHit] {
        try await backend.search(
            IndexQuery(text: text, limit: limit, allowedScopes: [scope])
        )
    }
}
