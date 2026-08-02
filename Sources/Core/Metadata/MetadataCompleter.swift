import Foundation
import ProviderGatewayKit

/// One finished, non-streamed model reply and what it consumed.
struct MetadataCompletion: Sendable, Equatable {
    let text: String
    let promptTokens: Int
    let completionTokens: Int
}

/// The seam a metadata ask reaches a model through.
///
/// A protocol rather than the provider directly, because every test in this feature needs to
/// script a *sequence* of replies — a malformed one followed by a good one is the whole point of
/// the repair loop — and scripting that at the HTTP layer would test `URLProtocol` instead.
protocol MetadataCompleting: Sendable {
    func complete(system: String, user: String) async throws -> MetadataCompletion
}

/// Why a metadata call failed, in words that survive being stringified twice.
///
/// Both packages downstream of this throw the error away and keep only `String(describing:)` of
/// it: `OutputRepairLoop` does it on the way into `RepairFailure.producerFailed`, and
/// `BatchProcessor` does it again on the way into `BatchItemError.message`. `ProviderError` is not
/// `CustomStringConvertible`, so without this wrapper a rate limit arrives in Diagnostics as
/// `rateLimited(retryAfter: Optional(Duration(...)))` — a Swift value dump where a fact belongs.
struct MetadataProviderFailure: Error, Sendable, Equatable, CustomStringConvertible {
    let summary: String

    var description: String { summary }

    init(summary: String) {
        self.summary = summary
    }

    init(_ error: ProviderError) {
        switch error {
        case let .rateLimited(retryAfter):
            guard let retryAfter else {
                self.summary = "rate limited by OpenRouter"
                return
            }
            self.summary = "rate limited by OpenRouter, retry after \(retryAfter.components.seconds)s"
        case .timeout:
            self.summary = "the metadata request timed out"
        case let .connectionFailed(message):
            self.summary = "could not reach OpenRouter: \(message)"
        case let .capabilityMismatch(message):
            self.summary = "OpenRouter rejected the metadata request: \(message)"
        }
    }
}

/// Sends one metadata ask to OpenRouter and waits for the whole answer.
///
/// Buffered rather than streamed, deliberately. A repair loop validates a finished reply, and a
/// half-arrived JSON object is not a smaller valid one — there is nothing to render progressively
/// and nothing to gain by trying. `ResponseProducing.produce` returns one `String` for the same
/// reason, so this is the shape the package already assumes.
struct OpenRouterMetadataCompleter: MetadataCompleting {
    private let configuration: OpenRouterConfiguration
    private let session: URLSession
    private let maxOutputTokens: Int

    init(
        configuration: OpenRouterConfiguration,
        session: URLSession = .shared,
        maxOutputTokens: Int = 256
    ) {
        var buffered = configuration
        buffered.streaming = false
        self.configuration = buffered
        self.session = session
        self.maxOutputTokens = maxOutputTokens
    }

    func complete(system: String, user: String) async throws -> MetadataCompletion {
        // A recorder per call, not the app's shared one. `UsageRecorder.mostRecent` is what
        // `TurnExecutor.account` reads to price the turn the user is watching, and two metadata
        // calls landing in it mid-turn would attribute their tokens to the user's message.
        let usage = UsageRecorder()
        let provider = OpenRouterProvider(
            configuration: configuration,
            session: session,
            usageObserver: usage
        )
        // A low temperature, not zero: these asks want one shape and little invention, but a
        // hard zero makes a model that got the shape wrong once get it wrong identically on the
        // repair attempt, which spends the whole budget re-reading the same mistake.
        let request = LLMRequest(
            messages: [
                LLMMessage(role: .system, content: system),
                LLMMessage(role: .user, content: user)
            ],
            maxOutputTokens: maxOutputTokens,
            temperature: 0.2
        )
        let text = try await Self.text(of: provider.stream(request: request))
        let recorded = await usage.mostRecent
        return MetadataCompletion(
            text: text,
            promptTokens: recorded?.promptTokens ?? 0,
            completionTokens: recorded?.completionTokens ?? 0
        )
    }

    static func text(of stream: AsyncThrowingStream<LLMStreamEvent, Error>) async throws -> String {
        var text = ""
        do {
            for try await event in stream {
                if case let .completed(response) = event { text = response.text }
            }
        } catch let error as ProviderError {
            throw MetadataProviderFailure(error)
        }
        return text
    }
}
