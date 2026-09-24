import Foundation
import StructuredOutputKit
import ToolIntegrityKit
import ToolRegistryKit

/// Renders a registered `ToolRegistryKit.ToolDefinition` as `ToolIntegrityKit.ToolDefinition` —
/// the shape its fingerprinting actually reads — the same kind of internal-catalogue-to-a-
/// specific-package's-wire-shape translation `ToolSchemaBridge` does for OpenRouter.
///
/// `ToolIntegrityKit` has no dependency on `StructuredOutputKit`, so `JSONSchema` is flattened
/// into `ToolParameterValue` here rather than in either package: kind, description, required and
/// enum values, and every nested schema (`properties`, `items`), recursively, so a change buried
/// three objects deep still moves the fingerprint.
enum ToolIntegrityBridge {
    static func integrityDefinition(
        for definition: ToolRegistryKit.ToolDefinition
    ) -> ToolIntegrityKit.ToolDefinition {
        ToolIntegrityKit.ToolDefinition(
            name: definition.name,
            description: definition.description,
            parameters: value(for: definition.parameters)
        )
    }

    static func value(for schema: JSONSchema) -> ToolIntegrityKit.ToolParameterValue {
        var fields: [String: ToolIntegrityKit.ToolParameterValue] = ["kind": .string(schema.kind.rawValue)]
        if let description = schema.description {
            fields["description"] = .string(description)
        }
        if let properties = schema.properties {
            fields["properties"] = .object(properties.mapValues { value(for: $0) })
        }
        if let required = schema.required, !required.isEmpty {
            fields["required"] = .array(required.sorted().map(ToolIntegrityKit.ToolParameterValue.string))
        }
        if let items = schema.items {
            fields["items"] = value(for: items.schema)
        }
        if let enumValues = schema.enumValues, !enumValues.isEmpty {
            fields["enumValues"] = .array(enumValues.sorted().map(ToolIntegrityKit.ToolParameterValue.string))
        }
        return .object(fields)
    }
}
