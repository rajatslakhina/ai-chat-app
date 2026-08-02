import Foundation
import ProviderGatewayKit
import StructuredOutputKit
import ToolRegistryKit

/// Renders `StructuredOutputKit.JSONSchema` as the JSON Schema object OpenRouter expects.
///
/// `ToolDefinition` is `Codable`, and sending its encoded form is a 400. The synthesized encoder
/// emits `{"kind":"object","properties":{"city":{"kind":"string"}}}` — the key is `kind`, not
/// `type`, and there is no `{"type":"function","function":{…}}` envelope. `JSONSchema` declares no
/// `CodingKeys` anywhere in StructuredOutputKit, so that is synthesized property-name encoding and
/// it is not going to change. The registry's definitions are an internal catalogue; this is the
/// wire form, and the two are deliberately different types of thing.
enum ToolSchemaBridge {
    /// One registered tool as the gateway's transport-level definition.
    static func wireDefinition(for definition: ToolRegistryKit.ToolDefinition) -> LLMToolDefinition {
        LLMToolDefinition(
            name: definition.name,
            toolDescription: definition.description,
            parameterSchema: parameters(for: definition.parameters)
        )
    }

    /// The complete `parameters` object for one tool.
    ///
    /// `properties` is forced to be present even when the schema declares none: several upstream
    /// providers reject a function whose `parameters` is absent, null, or has no properties object.
    static func parameters(for schema: JSONSchema) -> [String: LLMToolArgumentValue] {
        guard case var .object(fields) = node(schema) else { return [:] }
        if fields["type"] == nil { fields["type"] = .string("object") }
        if fields["properties"] == nil { fields["properties"] = .object([:]) }
        return fields
    }

    /// One schema node as a JSON Schema object.
    ///
    /// `JSONSchema.Kind.rawValue` is already the JSON Schema spelling of every case it models
    /// (`object`, `array`, `string`, `number`, `integer`, `boolean`, `null`), so the only thing
    /// wrong with the built-in encoding was the key it was filed under.
    static func node(_ schema: JSONSchema) -> LLMToolArgumentValue {
        var fields: [String: LLMToolArgumentValue] = ["type": .string(schema.kind.rawValue)]
        if let description = schema.description {
            fields["description"] = .string(description)
        }
        if let properties = schema.properties {
            fields["properties"] = .object(properties.mapValues { node($0) })
        }
        // An empty `required` array is legal but says nothing, and omitting it is how an optional
        // argument stays optional — the difference between `current_time` working and every
        // argument-less call coming back as `.invalidArguments`.
        if let required = schema.required, !required.isEmpty {
            fields["required"] = .array(required.sorted().map(LLMToolArgumentValue.string))
        }
        if let items = schema.items {
            fields["items"] = node(items.schema)
        }
        if let enumValues = schema.enumValues, !enumValues.isEmpty {
            fields["enum"] = .array(enumValues.map(LLMToolArgumentValue.string))
        }
        return .object(fields)
    }
}
