import BatchInferenceKit
import Foundation
import OutputRepairKit

/// Feeds one ask's prompts to a model and remembers what the whole conversation cost.
///
/// An `actor` because `OutputRepairLoop` calls `produce` once per attempt and every attempt is a
/// separately billed call. The loop hands back `attempts` but not tokens, so the counts have to
/// accumulate somewhere the loop cannot see — here.
actor MetadataProducer: ResponseProducing {
    private let completer: any MetadataCompleting
    private let system: String
    private var usage = BatchTokenUsage.zero

    init(completer: any MetadataCompleting, system: String) {
        self.completer = completer
        self.system = system
    }

    func produce(prompt: String) async throws -> String {
        let completion = try await completer.complete(system: system, user: prompt)
        usage += BatchTokenUsage(
            promptTokens: completion.promptTokens,
            completionTokens: completion.completionTokens
        )
        return completion.text
    }

    func spent() -> BatchTokenUsage { usage }
}

/// Why one metadata ask produced nothing usable.
///
/// It deliberately does not carry the rejected reply. `RepairFailure.exhausted` carries `lastRaw`,
/// and in a chat app that text routinely quotes the user's own message straight back — a
/// diagnostics pane is not where someone's typing belongs. Only the unresolved issues survive,
/// and those describe the shape rather than the content.
struct MetadataAskFailure: Error, Sendable, Equatable, CustomStringConvertible {
    enum Reason: Sendable, Equatable {
        /// The model never satisfied the contract. Every one of these attempts was billed.
        case exhausted(attempts: Int, unresolved: [String])
        /// The call itself failed. The model never got a chance to answer.
        case provider(attempt: Int, message: String)
        /// The user moved on. Not an error, and must never reach the screen as one.
        case cancelled
        /// A batch request id nothing was registered for — an app bug, not a model problem.
        case unknownAsk
    }

    let ask: String
    let reason: Reason

    /// Producer calls made before giving up, so the cost screen can attribute them.
    var attempts: Int {
        switch reason {
        case let .exhausted(attempts, _): return attempts
        case let .provider(attempt, _): return attempt
        case .cancelled, .unknownAsk: return 0
        }
    }

    var issues: [String] {
        guard case let .exhausted(_, unresolved) = reason else { return [] }
        return unresolved
    }

    var description: String {
        switch reason {
        case let .exhausted(attempts, unresolved):
            let listed = unresolved.isEmpty ? "no issue was recorded" : unresolved.joined(separator: "; ")
            return "\(ask): still invalid after \(attempts) attempt(s) — \(listed)"
        case let .provider(attempt, message):
            return "\(ask): the call failed on attempt \(attempt) — \(message)"
        case .cancelled:
            return "\(ask): cancelled"
        case .unknownAsk:
            return "\(ask): no ask is registered under this id"
        }
    }

    /// Classifies whatever `OutputRepairLoop.run` threw.
    ///
    /// Cancellation arrives in two incompatible shapes and both have to be caught. The loop's
    /// backoff `sleep` sits outside its own `do/catch`, so a task cancelled while backing off
    /// throws a bare `CancellationError`; a task cancelled during the model call is caught and
    /// re-wrapped as `producerFailed(message: "CancellationError()")`. Handling only the first
    /// shows an error to a user who deliberately walked away.
    static func make(ask: String, from error: Error) -> MetadataAskFailure {
        if error is CancellationError {
            return MetadataAskFailure(ask: ask, reason: .cancelled)
        }
        guard let failure = error as? RepairFailure else {
            return MetadataAskFailure(
                ask: ask,
                reason: .provider(attempt: 1, message: String(describing: error))
            )
        }
        switch failure {
        case let .exhausted(attempts, issueHistory, _):
            return MetadataAskFailure(
                ask: ask,
                reason: .exhausted(
                    attempts: attempts,
                    unresolved: (issueHistory.last ?? []).map(\.description)
                )
            )
        case let .producerFailed(attempt, message):
            guard !message.contains("CancellationError") else {
                return MetadataAskFailure(ask: ask, reason: .cancelled)
            }
            return MetadataAskFailure(ask: ask, reason: .provider(attempt: attempt, message: message))
        }
    }
}

/// Runs whichever ask the batch admits, through that ask's own repair loop.
///
/// One instance per generation. `BatchProcessor` reports per-item outcomes but not how many
/// attempts each one took inside the executor, so the attempt counts are collected here and read
/// back afterwards; a shared instance would mix two conversations' counts together.
actor MetadataBatchExecutor: BatchExecuting {
    /// What one ask cost and whether it converged.
    struct AskOutcome: Sendable, Equatable {
        /// Producer calls made. Each one was billed.
        var attempts: Int
        /// Every issue fed back to the model, in order. Empty when the first attempt validated.
        var issues: [String]
        var failure: MetadataAskFailure?

        var repaired: Bool { failure == nil && attempts > 1 }
    }

    private let asks: [String: MetadataAsk]
    private let loops: [String: OutputRepairLoop<MetadataContract>]
    private let completer: any MetadataCompleting
    private var outcomes: [String: AskOutcome] = [:]

    init(
        asks: [MetadataAsk],
        loops: [String: OutputRepairLoop<MetadataContract>],
        completer: any MetadataCompleting
    ) {
        var indexed: [String: MetadataAsk] = [:]
        for ask in asks { indexed[ask.id] = ask }
        self.asks = indexed
        self.loops = loops
        self.completer = completer
    }

    func recorded() -> [String: AskOutcome] { outcomes }

    func execute(_ request: BatchRequest) async throws -> BatchResponse {
        guard let ask = asks[request.id], let loop = loops[request.id] else {
            let failure = MetadataAskFailure(ask: request.id, reason: .unknownAsk)
            outcomes[request.id] = AskOutcome(attempts: 0, issues: [], failure: failure)
            throw failure
        }
        let producer = MetadataProducer(completer: completer, system: ask.system)
        do {
            let run = try await loop.run(initialPrompt: request.prompt, producer: producer)
            outcomes[request.id] = AskOutcome(
                attempts: run.attempts,
                issues: run.issueHistory.flatMap { $0.map(\.description) },
                failure: nil
            )
            return BatchResponse(id: request.id, text: run.output, usage: await producer.spent())
        } catch {
            let failure = MetadataAskFailure.make(ask: request.id, from: error)
            outcomes[request.id] = AskOutcome(
                attempts: failure.attempts,
                issues: failure.issues,
                failure: failure
            )
            throw failure
        }
    }
}
