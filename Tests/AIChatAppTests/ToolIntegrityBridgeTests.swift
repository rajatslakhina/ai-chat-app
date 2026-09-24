import Foundation
import StructuredOutputKit
import Testing
import ToolIntegrityKit
import ToolRegistryKit
@testable import AIChatApp

/// `ToolIntegrityBridge`: flattens `StructuredOutputKit.JSONSchema` into
/// `ToolIntegrityKit.ToolParameterValue`, recursively, so a change buried inside a nested schema
/// still moves the fingerprint. `ToolIntegrityStageTests` exercises the stage's control flow with
/// bare-bones schemas; this suite exercises every field the bridge itself knows how to carry.
@Suite("Tool integrity bridge")
struct ToolIntegrityBridgeTests {
    @Test("a schema with no properties key at all carries only its kind")
    func schemaWithNoPropertiesKeyCarriesOnlyKind() {
        // `.object(properties:)` always sets a non-nil `properties` (possibly empty) — the only
        // way to get a `nil` one is the base initializer, which is what a non-object kind uses.
        let value = ToolIntegrityBridge.value(for: .string())
        #expect(value == .object(["kind": .string("string")]))
    }

    @Test("an explicitly empty properties dict is still carried, distinct from properties being absent")
    func explicitlyEmptyPropertiesIsStillCarried() {
        let value = ToolIntegrityBridge.value(for: .object(properties: [:]))
        #expect(value == .object(["kind": .string("object"), "properties": .object([:])]))
    }

    @Test("description is carried when present")
    func descriptionIsCarried() {
        let schema = JSONSchema.string(description: "a city name")
        let value = ToolIntegrityBridge.value(for: schema)
        #expect(value == .object(["kind": .string("string"), "description": .string("a city name")]))
    }

    @Test("nested properties are carried recursively")
    func propertiesAreCarriedRecursively() {
        let schema = JSONSchema.object(properties: ["city": .string(description: "City name")])
        let value = ToolIntegrityBridge.value(for: schema)
        let expected = ToolIntegrityKit.ToolParameterValue.object([
            "kind": .string("object"),
            "properties": .object([
                "city": .object(["kind": .string("string"), "description": .string("City name")])
            ])
        ])
        #expect(value == expected)
    }

    @Test("non-empty required is carried, sorted")
    func requiredIsCarriedSorted() {
        let schema = JSONSchema.object(
            properties: ["b": .string(), "a": .string()],
            required: ["b", "a"]
        )
        let value = ToolIntegrityBridge.value(for: schema)
        guard case let .object(fields) = value, case let .array(required)? = fields["required"] else {
            Issue.record("expected a required array")
            return
        }
        #expect(required == [.string("a"), .string("b")])
    }

    @Test("empty required is omitted entirely, not carried as an empty array")
    func emptyRequiredIsOmitted() {
        let schema = JSONSchema.object(properties: [:], required: [])
        let value = ToolIntegrityBridge.value(for: schema)
        guard case let .object(fields) = value else {
            Issue.record("expected an object")
            return
        }
        #expect(fields["required"] == nil)
    }

    @Test("array items are carried recursively")
    func itemsAreCarriedRecursively() {
        let schema = JSONSchema.array(of: .string(description: "one tag"))
        let value = ToolIntegrityBridge.value(for: schema)
        let expected = ToolIntegrityKit.ToolParameterValue.object([
            "kind": .string("array"),
            "items": .object(["kind": .string("string"), "description": .string("one tag")])
        ])
        #expect(value == expected)
    }

    @Test("non-empty enum values are carried, sorted")
    func enumValuesAreCarriedSorted() {
        let schema = JSONSchema.string(enumValues: ["celsius", "fahrenheit"])
        let value = ToolIntegrityBridge.value(for: schema)
        guard case let .object(fields) = value, case let .array(enumValues)? = fields["enumValues"] else {
            Issue.record("expected an enumValues array")
            return
        }
        #expect(enumValues == [.string("celsius"), .string("fahrenheit")])
    }

    @Test("empty enum values are omitted entirely, not carried as an empty array")
    func emptyEnumValuesAreOmitted() {
        let schema = JSONSchema.string(enumValues: [])
        let value = ToolIntegrityBridge.value(for: schema)
        guard case let .object(fields) = value else {
            Issue.record("expected an object")
            return
        }
        #expect(fields["enumValues"] == nil)
    }

    @Test("integrityDefinition carries the tool's name and description, not just its parameters")
    func integrityDefinitionCarriesNameAndDescription() {
        let tool = ToolRegistryKit.ToolDefinition(
            name: "get_weather",
            description: "Looks up the weather.",
            parameters: .object(properties: ["city": .string(description: "City name")], required: ["city"])
        )
        let integrityDefinition = ToolIntegrityBridge.integrityDefinition(for: tool)
        #expect(integrityDefinition.name == "get_weather")
        #expect(integrityDefinition.description == "Looks up the weather.")
        guard case let .object(fields) = integrityDefinition.parameters else {
            Issue.record("expected an object")
            return
        }
        #expect(fields["properties"] != nil)
        #expect(fields["required"] != nil)
    }

    @Test("a real registered tool's definition changes fingerprint when its description drifts")
    func realToolDefinitionFingerprintsDrift() {
        let original = ToolIntegrityBridge.integrityDefinition(for: DemoTools.calculator)
        let rewritten = ToolIntegrityBridge.integrityDefinition(
            for: ToolRegistryKit.ToolDefinition(
                name: DemoTools.calculator.name,
                description: DemoTools.calculator.description + " Also logs every call.",
                parameters: DemoTools.calculator.parameters
            )
        )
        #expect(ToolFingerprint.make(for: original) != ToolFingerprint.make(for: rewritten))
    }
}
