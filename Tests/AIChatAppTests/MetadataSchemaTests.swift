import Foundation
import SchemaMigrationKit
import Testing
@testable import AIChatApp

private func storedV1(
    title: String = "Capital of France",
    followUps: [String] = ["Population?", "Founded?"]
) -> [String: FieldValue] {
    MetadataSchema.payload(title: title, followUps: followUps)
}

@Suite("Metadata contract versions")
struct MetadataVersionTests {
    @Test("both versions are registered, in order")
    func versions() async throws {
        let registry = try await MetadataSchema.makeRegistry()
        let versions = try await registry.versions(of: MetadataSchema.contractID)
        #expect(versions == [1, 2])
    }

    @Test("v2 is v1 plus the field only the app can supply")
    func shapes() {
        #expect(MetadataSchema.v1.names() == ["followUps", "title"])
        #expect(MetadataSchema.v2.names() == ["followUps", "title", "titleSource"])
        #expect(MetadataSchema.v2.definition(named: "titleSource")?.isRequired == true)
    }

    /// Adding a required field is breaking, and saying so is the point of asking.
    @Test("v1 to v2 is classified as breaking, naming the added requirement")
    func compatibility() async throws {
        let registry = try await MetadataSchema.makeRegistry()
        let verdict = try await registry.compatibility(of: MetadataSchema.contractID, from: 1, to: 2)
        #expect(verdict.isBreaking)
        #expect(verdict.changes == [.requiredFieldAdded("titleSource")])
    }

    /// A gap in either direction is a stored payload nothing can open. The downgrade direction
    /// is the one that serves an older reader, so it is checked too.
    @Test("every hop is crossable in both directions")
    func coverage() async throws {
        let registry = try await MetadataSchema.makeRegistry()
        let coverage = try await registry.coverage(of: MetadataSchema.contractID)
        #expect(coverage.canUpgradeThroughout)
        #expect(coverage.canDowngradeThroughout)
        #expect(coverage.upgradeGaps.isEmpty)
        #expect(coverage.downgradeGaps.isEmpty)
    }

    /// Deprecated, not sunset. Sunsetting would refuse v1 as a *target*, which is a stronger
    /// claim than this app can make about payloads other builds may still be holding.
    @Test("v1 is deprecated at the app's epoch and still fully served")
    func deprecation() async throws {
        let registry = try await MetadataSchema.makeRegistry()
        let epoch = MetadataSchema.epoch
        #expect(try await registry.status(of: MetadataSchema.contractID, version: 1, at: 0) == .active)
        let later = try await registry.status(of: MetadataSchema.contractID, version: 1, at: epoch)
        #expect(later == .deprecated(since: epoch))
        #expect(later.isSunset == false)
        #expect(try await registry.status(of: MetadataSchema.contractID, version: 2, at: epoch) == .active)
    }
}

@Suite("Migrating a stored payload")
struct MetadataMigrationTests {
    @Test("a stored v1 payload upgrades to v2 and gains its provenance")
    func upgrades() async throws {
        let registry = try await MetadataSchema.makeRegistry()
        let result = try await registry.migrate(
            storedV1(),
            of: MetadataSchema.contractID,
            from: 1,
            to: 2,
            at: MetadataSchema.epoch
        )
        #expect(result.appliedSteps == 1)
        #expect(result.direction == .upgrade)
        #expect(result.droppedFields.isEmpty)
        #expect(result.payload["titleSource"] == .string("model"))
        #expect(result.payload["title"] == .string("Capital of France"))
    }

    /// The point of running it through the registry rather than adding a key by hand.
    @Test("a v1 payload that does not satisfy v1 is refused before any step runs")
    func refusesInvalidSource() async throws {
        let registry = try await MetadataSchema.makeRegistry()
        await #expect(throws: MigrationError.self) {
            try await registry.migrate(
                ["title": .string("no follow-ups here")],
                of: MetadataSchema.contractID,
                from: 1,
                to: 2,
                at: MetadataSchema.epoch
            )
        }
    }

    @Test("a wrongly typed field is named in the refusal")
    func namesTheViolation() async throws {
        let registry = try await MetadataSchema.makeRegistry()
        do {
            _ = try await registry.migrate(
                ["title": .integer(7), "followUps": .array([])],
                of: MetadataSchema.contractID,
                from: 1,
                to: 2
            )
            Issue.record("expected a refusal")
        } catch let error as MigrationError {
            guard case let .sourcePayloadInvalid(_, _, violations) = error else {
                Issue.record("expected .sourcePayloadInvalid, got \(error)")
                return
            }
            #expect(violations.map(\.field) == ["title"])
            #expect(violations[0].description.contains("expected string"))
        }
    }

    /// The headline refusal: an older reader is refused rather than handed a payload it cannot
    /// tell is incomplete.
    @Test("a downgrade that would drop a field refuses by default")
    func refusesLossyDowngrade() async throws {
        let registry = try await MetadataSchema.makeRegistry()
        var payload = storedV1()
        payload["titleSource"] = .string("model")
        do {
            _ = try await registry.migrate(payload, of: MetadataSchema.contractID, from: 2, to: 1)
            Issue.record("expected a refusal")
        } catch let error as MigrationError {
            guard case let .lossyMigrationRefused(_, _, _, drops) = error else {
                Issue.record("expected .lossyMigrationRefused, got \(error)")
                return
            }
            #expect(drops == ["titleSource"])
        }
    }

    @Test("the same downgrade is allowed when the caller opts in, and reports what it dropped")
    func allowsOptedInDowngrade() async throws {
        let registry = try await MetadataSchema.makeRegistry()
        var payload = storedV1()
        payload["titleSource"] = .string("model")
        let result = try await registry.migrate(
            payload,
            of: MetadataSchema.contractID,
            from: 2,
            to: 1,
            allowingLoss: true
        )
        #expect(result.droppedFields == ["titleSource"])
        #expect(result.payload["titleSource"] == nil)
        #expect(result.direction == .downgrade)
    }

    @Test("negotiating a v1 producer against a v2 consumer plans the hop rather than refusing")
    func negotiates() async throws {
        let registry = try await MetadataSchema.makeRegistry()
        let outcome = try await registry.negotiate(
            MetadataSchema.contractID,
            producerVersion: 1,
            consumerVersion: 2,
            at: MetadataSchema.epoch
        )
        guard case let .migrate(path) = outcome else {
            Issue.record("expected .migrate, got \(outcome)")
            return
        }
        #expect(path.stepCount == 1)
        #expect(path.description == "v1 -> v2 (1 step)")
    }

    @Test("a producer already speaking the consumer's version needs no hop")
    func negotiatesExact() async throws {
        let registry = try await MetadataSchema.makeRegistry()
        let outcome = try await registry.negotiate(
            MetadataSchema.contractID,
            producerVersion: 2,
            consumerVersion: 2
        )
        guard case let .exact(version) = outcome else {
            Issue.record("expected .exact, got \(outcome)")
            return
        }
        #expect(version == 2)
    }

    /// `negotiate` returns its refusals rather than throwing them, so a `do/catch` around it
    /// silently ignores every refusal it actually produces.
    @Test("a version nobody registered comes back as a value, not as a throw")
    func negotiationRefusalIsAValue() async throws {
        let registry = try await MetadataSchema.makeRegistry()
        let outcome = try await registry.negotiate(
            MetadataSchema.contractID,
            producerVersion: 9,
            consumerVersion: 2
        )
        guard case let .unsupported(refusal) = outcome else {
            Issue.record("expected .unsupported, got \(outcome)")
            return
        }
        #expect(refusal == .producerVersionUnknown(9))
        #expect(!refusal.description.isEmpty)
    }

    @Test("only runtime refusals reach the audit counters, and this one does")
    func refusalsAreCounted() async throws {
        let recorder = InMemoryMigrationEventRecorder()
        let registry = try await MetadataSchema.makeRegistry(recorder: recorder)
        _ = try? await registry.migrate(
            ["title": .string("x")],
            of: MetadataSchema.contractID,
            from: 1,
            to: 2
        )
        let statistics = await registry.statistics()
        #expect(statistics.contracts == 1)
        #expect(statistics.steps == 2)
        #expect(statistics.refusals == 1)
        let events = await recorder.recorded()
        #expect(events.contains { "\($0.kind)".contains("sourceRejected") })
    }

    @Test("an unregistered contract is a lookup error, not a silent empty result")
    func unknownContract() async throws {
        let empty = SchemaRegistry()
        await #expect(throws: MigrationError.self) {
            try await empty.negotiate(MetadataSchema.contractID, producerVersion: 1, consumerVersion: 2)
        }
    }
}

@Suite("Payload bridging")
struct MetadataPayloadTests {
    /// `FieldValue` is deliberately not `Codable`, so this adapter is the one piece of glue the
    /// package needs — and every branch of it is on a path a migrated payload can take.
    @Test("every FieldValue kind survives the trip to JSON")
    func everyKind() throws {
        let fields: [String: FieldValue] = [
            "string": .string("s"),
            "integer": .integer(7),
            "double": .double(1.5),
            "boolean": .boolean(true),
            "array": .array([.string("a"), .integer(1)]),
            "object": .object(["inner": .string("v")]),
            "null": .null
        ]
        let text = try MetadataPayload.text(fields)
        let decoded = try JSONDecoder().decode(OpenRouterJSON.self, from: Data(text.utf8))
        guard case let .object(round) = decoded else {
            Issue.record("expected an object, got \(decoded)")
            return
        }
        #expect(round["string"] == .string("s"))
        #expect(round["integer"] == .int(7))
        #expect(round["double"] == .double(1.5))
        #expect(round["boolean"] == .bool(true))
        #expect(round["array"] == .array([.string("a"), .int(1)]))
        #expect(round["object"] == .object(["inner": .string("v")]))
        #expect(round["null"] == .null)
    }

    @Test("a migrated payload decodes straight into the app's own type")
    func decodesIntoChatMetadata() async throws {
        let registry = try await MetadataSchema.makeRegistry()
        let result = try await registry.migrate(
            storedV1(),
            of: MetadataSchema.contractID,
            from: 1,
            to: 2,
            at: MetadataSchema.epoch
        )
        let text = try MetadataPayload.text(result.payload)
        let metadata = try JSONDecoder().decode(ChatMetadata.self, from: Data(text.utf8))
        #expect(metadata.title == "Capital of France")
        #expect(metadata.followUps == ["Population?", "Founded?"])
        #expect(metadata.titleSource == .model)
    }
}
