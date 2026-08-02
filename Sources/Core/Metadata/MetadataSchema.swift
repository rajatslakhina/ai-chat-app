import Foundation
import SchemaMigrationKit

/// The versioned contract conversation metadata is produced under and rendered from.
///
/// Two versions, and the gap between them is real rather than illustrative. The **model** answers
/// in v1 (`title` + `followUps`) because that is all a model can honestly know. The **app**
/// renders v2, which adds `titleSource` — a fact about who wrote the title, which only this app
/// can supply. Every model-named conversation therefore crosses a genuine v1 → v2 hop before
/// anything reaches the screen, and a payload stored by a build that predates `titleSource`
/// crosses exactly the same hop.
enum MetadataSchema {
    static let contractID: ContractID = "chat.metadata"

    /// The shape a model answers in.
    static let producerVersion: SchemaVersion = 1
    /// The shape the navigation bar and the chip row read.
    static let consumerVersion: SchemaVersion = 2

    /// The app's schema epoch — logical time for the deprecation window, not a clock.
    ///
    /// `SchemaMigrationKit` never reads a clock; `at tick:` is whatever integer the caller calls
    /// "now". A build number makes "v1 was deprecated at epoch 2" an exact, testable statement,
    /// where a wall-clock timestamp would make it a race.
    static let epoch = 2

    static let v1 = ContractSchema([
        .required("title", .string),
        .required("followUps", .array)
    ])

    static let v2 = ContractSchema([
        .required("title", .string),
        .required("followUps", .array),
        .required("titleSource", .string)
    ])

    /// Both versions in one declaration, which is the only way this package accepts them: adding
    /// a version later would silently invalidate the adjacency of steps already registered.
    static var definition: ContractDefinition {
        ContractDefinition(
            id: contractID,
            versions: [
                ContractVersionDefinition(version: producerVersion, schema: v1),
                ContractVersionDefinition(version: consumerVersion, schema: v2)
            ]
        )
    }

    /// v1 → v2. Fills in `titleSource` with `model`.
    ///
    /// Not a guess. A v1 payload exists only because a model wrote its title — the fallback path
    /// was introduced together with v2 and has never written a v1 payload — so `model` is the one
    /// value this hop can assert without inventing anything.
    static var upgrade: PayloadMigration {
        PayloadMigration(from: producerVersion, to: consumerVersion) { payload in
            var next = payload
            next["titleSource"] = .string(TitleSource.model.rawValue)
            return next
        }
    }

    /// v2 → v1, for an older reader. Declared lossy, because it is.
    ///
    /// Nothing in the send path calls this: the app only ever moves forward. It is registered so
    /// `coverage(of:)` reports no gap in either direction, which is the check that turns "we
    /// think every stored payload can be read" into something a test can assert. The declaration
    /// also earns its keep by making a downgrade *refuse* rather than silently truncate.
    static var downgrade: PayloadMigration {
        PayloadMigration(
            from: consumerVersion,
            to: producerVersion,
            loss: .lossy(drops: ["titleSource"])
        ) { payload in
            var next = payload
            next.removeValue(forKey: "titleSource")
            return next
        }
    }

    /// Builds the process-wide registry.
    ///
    /// One-shot: `register` throws `.duplicateContract` on a second call, so this belongs in the
    /// composition root and never in a SwiftUI `.task`, which re-runs on identity change.
    static func makeRegistry(
        recorder: (any MigrationEventRecording)? = nil
    ) async throws -> SchemaRegistry {
        let registry = SchemaRegistry(recorder: recorder)
        try await registry.register(definition)
        try await registry.registerStep(upgrade, for: contractID)
        try await registry.registerStep(downgrade, for: contractID)
        // Deprecated, not sunset. Deprecation is advisory here — v1 is the legacy shape and this
        // build never writes it — while a sunset would refuse v1 as a *target*, which is a
        // stronger claim than the app can make about payloads other builds may still be holding.
        try await registry.deprecate(
            contractID,
            version: producerVersion,
            notice: DeprecationNotice(deprecatedAt: epoch)
        )
        return registry
    }

    /// The v1 payload a decoded pair of drafts makes.
    static func payload(title: String, followUps: [String]) -> [String: FieldValue] {
        [
            "title": .string(title),
            "followUps": .array(followUps.map(FieldValue.string))
        ]
    }
}

/// Bridges a migrated payload back into bytes the app's decoders understand.
///
/// `FieldValue` is deliberately not `Codable` — the package owns its own JSON vocabulary so it
/// depends on nothing — so this adapter is the one piece of glue it needs. Going through JSON
/// text rather than reading fields out by hand means the migrated payload is checked against
/// `ChatMetadata.jsonSchema` and `Decodable` on the way in, so a migration step that produced
/// something the app cannot use is caught at the hop rather than three screens later.
enum MetadataPayload {
    static func data(_ fields: [String: FieldValue]) throws -> Data {
        try JSONEncoder().encode(json(fields))
    }

    /// The same bytes as text, for the decoders that take a `String`.
    ///
    /// `optional_data_string_conversion` is disabled for exactly this line, and the rule is wrong
    /// here. It exists because `String(decoding:as:)` replaces invalid bytes with U+FFFD instead
    /// of reporting them, which matters when the bytes came from somewhere untrusted. These came
    /// from `JSONEncoder` on the line above, which emits UTF-8 by construction — so the failable
    /// form's `nil` branch was a fallback no payload could reach, and a fallback that has never
    /// run is a guess about what the app does rather than a thing it has been seen doing.
    static func text(_ fields: [String: FieldValue]) throws -> String {
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: try data(fields), as: UTF8.self)
    }

    static func json(_ fields: [String: FieldValue]) -> OpenRouterJSON {
        .object(fields.mapValues(json))
    }

    static func json(_ value: FieldValue) -> OpenRouterJSON {
        switch value {
        case let .string(inner): return .string(inner)
        case let .integer(inner): return .int(inner)
        case let .double(inner): return .double(inner)
        case let .boolean(inner): return .bool(inner)
        case let .array(inner): return .array(inner.map(json))
        case let .object(inner): return .object(inner.mapValues(json))
        case .null: return .null
        }
    }
}
