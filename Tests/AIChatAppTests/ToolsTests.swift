import Foundation
import ProviderGatewayKit
import StructuredOutputKit
import Testing
import ToolAuthorityKit
import ToolRegistryKit
@testable import AIChatApp

@Suite("Arithmetic evaluator")
struct ArithmeticEvaluatorTests {
    @Test("multiplication binds tighter than addition, so the grammar has to have two levels")
    func precedence() throws {
        #expect(try ArithmeticEvaluator.evaluate("2 + 3 * 4") == 14)
        #expect(try ArithmeticEvaluator.evaluate("(2 + 3) * 4") == 20)
        #expect(try ArithmeticEvaluator.evaluate("100 / 4 / 5") == 5)
    }

    @Test("unary minus applies to a factor rather than flipping the whole expression")
    func unaryMinus() throws {
        #expect(try ArithmeticEvaluator.evaluate("-3 + 10") == 7)
        #expect(try ArithmeticEvaluator.evaluate("10 - -3") == 13)
        #expect(try ArithmeticEvaluator.evaluate("-(2 + 3) * 2") == -10)
    }

    @Test("decimals and the typographic signs models actually emit are accepted")
    func decimalsAndSigns() throws {
        #expect(try ArithmeticEvaluator.evaluate("1.5 * 4") == 6)
        #expect(try ArithmeticEvaluator.evaluate("7 × 6") == 42)
        #expect(try ArithmeticEvaluator.evaluate("84 ÷ 2") == 42)
    }

    /// The path that gives the round trip a genuine `.handlerThrew`, rather than a fabricated one.
    @Test("division by zero is refused rather than reported as infinity")
    func divisionByZero() {
        #expect(throws: ArithmeticError.dividedByZero) {
            try ArithmeticEvaluator.evaluate("10 / 0")
        }
    }

    @Test("malformed input names the character and position rather than failing anonymously")
    func malformed() throws {
        #expect(throws: ArithmeticError.empty) { try ArithmeticEvaluator.evaluate("   ") }
        #expect(throws: ArithmeticError.unexpectedEnd) { try ArithmeticEvaluator.evaluate("2 +") }
        #expect(throws: ArithmeticError.unbalancedParenthesis) {
            try ArithmeticEvaluator.evaluate("(2 + 3")
        }
        #expect(throws: ArithmeticError.unexpectedCharacter("a", at: 0)) {
            try ArithmeticEvaluator.evaluate("abc")
        }
        #expect(throws: ArithmeticError.unexpectedCharacter(")", at: 3)) {
            try ArithmeticEvaluator.evaluate("2+3)")
        }
    }

    @Test("every error says something a model could act on")
    func descriptions() {
        let errors: [ArithmeticError] = [
            .empty, .unexpectedEnd, .unexpectedCharacter("z", at: 4),
            .unbalancedParenthesis, .dividedByZero, .notFinite
        ]
        for error in errors {
            #expect(!error.description.isEmpty)
            #expect(!error.description.contains("ArithmeticError"), "\(error.description)")
        }
    }
}

@Suite("The registered tools do real work")
struct DemoToolsTests {
    private func handle(
        _ handler: ClosureToolHandler,
        _ arguments: JSONValue
    ) async throws -> JSONValue {
        try await handler.handle(arguments: arguments)
    }

    @Test("the calculator computes its answer rather than echoing a canned one")
    func calculatorComputes() async throws {
        let result = try await handle(
            DemoTools.calculatorHandler(),
            .object(["expression": .string("(3 + 4) * 12")])
        )
        #expect(result == .object([
            "expression": .string("(3 + 4) * 12"),
            "result": .number(84)
        ]))
    }

    @Test("a calculator failure reaches the registry as its own sentence")
    func calculatorThrows() async {
        await #expect(throws: ArithmeticError.dividedByZero) {
            try await handle(DemoTools.calculatorHandler(), .object(["expression": .string("1/0")]))
        }
    }

    @Test("the clock reports the instant it was given, in the zone it was asked for")
    func clockUsesInjectedInstant() async throws {
        let instant = Date(timeIntervalSince1970: 1_772_000_000)
        let result = try await handle(
            DemoTools.currentTimeHandler(now: { instant }),
            .object(["timeZone": .string("Asia/Kolkata")])
        )
        guard case let .object(fields) = result else {
            Issue.record("expected an object, got \(result)")
            return
        }
        #expect(fields["timeZone"] == .string("Asia/Kolkata"))
        #expect(fields["unixSeconds"] == .number(1_772_000_000))
        #expect(fields["iso8601"] == .string("2026-02-25T11:43:20+05:30"))
        #expect(fields["readable"] == .string("Wednesday 25 February 2026 at 11:43"))
    }

    @Test("no time zone means UTC rather than whatever the simulator is set to")
    func clockDefaultsToUTC() async throws {
        let instant = Date(timeIntervalSince1970: 0)
        let result = try await handle(DemoTools.currentTimeHandler(now: { instant }), .object([:]))
        guard case let .object(fields) = result else {
            Issue.record("expected an object")
            return
        }
        #expect(fields["timeZone"] == .string("GMT"))
        #expect(fields["iso8601"] == .string("1970-01-01T00:00:00Z"))
    }

    /// A blank string is what OpenRouter sends for an argument the model chose to omit.
    @Test("a blank time zone is treated as absent rather than as an unknown zone")
    func blankZoneIsAbsent() async throws {
        let result = try await handle(
            DemoTools.currentTimeHandler(now: { Date(timeIntervalSince1970: 0) }),
            .object(["timeZone": .string("   ")])
        )
        guard case let .object(fields) = result else {
            Issue.record("expected an object")
            return
        }
        #expect(fields["timeZone"] == .string("GMT"))
    }

    @Test("an unknown time zone is refused with the identifier that was wrong")
    func unknownZone() async {
        await #expect(throws: ClockToolError.unknownTimeZone("Mars/Olympus")) {
            try await handle(
                DemoTools.currentTimeHandler(),
                .object(["timeZone": .string("Mars/Olympus")])
            )
        }
        #expect(ClockToolError.unknownTimeZone("x").description.contains("IANA"))
    }

    @Test("a schema mismatch surfaces as a sentence rather than a crash")
    func argumentMismatch() async {
        await #expect(throws: ToolArgumentError.missingString(field: "expression")) {
            try await handle(DemoTools.calculatorHandler(), .object(["expression": .number(1)]))
        }
        #expect(ToolArgumentError.missingString(field: "e").description.contains("\"e\""))
    }

    @Test("both tools survive a real dispatch through the registry")
    func dispatchThroughRegistry() async {
        let registry = ToolRegistryKit.ToolRegistry()
        await registry.register(DemoTools.calculator, handler: DemoTools.calculatorHandler())
        await registry.register(DemoTools.currentTime, handler: DemoTools.currentTimeHandler())

        let result = await registry.dispatch(
            ToolRegistryKit.ToolCallRequest(
                id: "1",
                toolName: DemoTools.calculatorName,
                argumentsJSON: Data(#"{"expression":"6*7"}"#.utf8)
            )
        )
        #expect(result.outcome == .success(.object([
            "expression": .string("6*7"),
            "result": .number(42)
        ])))

        // Registered with an empty `required` list precisely so this call works.
        let clock = await registry.dispatch(
            ToolRegistryKit.ToolCallRequest(
                id: "2",
                toolName: DemoTools.clockName,
                argumentsJSON: ToolRoundTrip.normalized(Data())
            )
        )
        guard case .success = clock.outcome else {
            Issue.record("an argument-less call must not be a schema violation: \(clock.outcome)")
            return
        }
    }
}

@Suite("Tool schema on the wire")
struct ToolSchemaBridgeTests {
    /// The bug this exists to prevent: `ToolDefinition` is `Codable`, and its encoded form is not
    /// the OpenRouter tool shape. Sending it raw is a 400.
    @Test("a registry definition renders as JSON Schema, not as the package's own encoding")
    func rendersJSONSchema() throws {
        let wire = ToolSchemaBridge.wireDefinition(for: DemoTools.calculator)
        #expect(wire.name == "calculator")
        #expect(wire.parameterSchema["type"] == .string("object"))
        #expect(wire.parameterSchema["required"] == .array([.string("expression")]))

        guard case let .object(properties)? = wire.parameterSchema["properties"],
              case let .object(expression)? = properties["expression"] else {
            Issue.record("the properties object did not survive translation")
            return
        }
        #expect(expression["type"] == .string("string"), "the key is `type`, never `kind`")
        #expect(expression["description"] != nil)
    }

    /// An optional argument that comes out required is how every argument-less call turns into a
    /// schema violation before the handler ever runs.
    @Test("an optional argument is omitted from required rather than inferred into it")
    func optionalStaysOptional() {
        let wire = ToolSchemaBridge.wireDefinition(for: DemoTools.currentTime)
        #expect(wire.parameterSchema["required"] == nil)
        #expect(wire.parameterSchema["properties"] != nil)
    }

    @Test("array, enum and integer nodes each carry their JSON Schema spelling")
    func richerNodes() {
        let schema = JSONSchema.object(
            properties: [
                "unit": .string(description: "d", enumValues: ["c", "f"]),
                "days": .integer(description: "how many"),
                "cities": .array(of: .string())
            ],
            required: ["unit"]
        )
        guard case let .object(fields) = ToolSchemaBridge.node(schema),
              case let .object(properties)? = fields["properties"] else {
            Issue.record("expected an object node")
            return
        }
        guard case let .object(unit)? = properties["unit"],
              case let .object(days)? = properties["days"],
              case let .object(cities)? = properties["cities"] else {
            Issue.record("expected three property nodes")
            return
        }
        #expect(unit["enum"] == .array([.string("c"), .string("f")]))
        #expect(days["type"] == .string("integer"))
        #expect(cities["items"] == .object(["type": .string("string")]))
    }

    @Test("a schema that is not an object still yields a usable parameters object")
    func nonObjectSchema() {
        let parameters = ToolSchemaBridge.parameters(for: .string(description: "odd"))
        #expect(parameters["type"] == .string("string"))
        #expect(parameters["properties"] == .object([:]), "a null properties object is a 400")
    }
}

@Suite("Tool authority gate")
struct ToolAuthorityGateTests {
    private func gate(
        _ capabilities: [Capability],
        maxToolUses: Int = 32
    ) -> ToolAuthorityGate {
        ToolAuthorityGate(capabilities: capabilities, maxToolUses: maxToolUses)
    }

    @Test("a granted, model-authored call is allowed and says which grant funded it")
    func allowed() async {
        let subject = gate(ToolAuthorityGate.readOnly(tools: ["calculator"]))
        let verdict = await subject.decide(
            tool: "calculator",
            arguments: #"{"expression":"1+1"}"#,
            conversationID: "conv-1",
            provenance: .modelAuthored
        )
        guard case let .allowed(detail) = verdict else {
            Issue.record("expected .allowed, got \(verdict)")
            return
        }
        #expect(detail.contains("conv-conv-1"))
        #expect(detail.contains("31 use(s) left"), "usesRemaining is counted after the increment")
    }

    @Test("a tool with no capability is denied with the action that resolves it")
    func deniedForMissingCapability() async {
        let subject = gate(ToolAuthorityGate.readOnly(tools: ["current_time"]))
        let verdict = await subject.decide(
            tool: "calculator",
            arguments: "{}",
            conversationID: "conv-1",
            provenance: .modelAuthored
        )
        guard case let .denied(refusal) = verdict else {
            Issue.record("expected .denied, got \(verdict)")
            return
        }
        #expect(refusal.stage == .toolAuthority)
        #expect(refusal.recovery == .approveTool(name: "calculator"))
        #expect(refusal.recoveryTitle == "Approve calculator")
        #expect(refusal.explanation == "no capability for tool 'calculator'")
    }

    /// The indirect-prompt-injection stop, and the reason `Provenance` exists at all.
    @Test("arguments shaped by a retrieved page are denied against a model-authored ceiling")
    func deniedForProvenance() async {
        let subject = gate(ToolAuthorityGate.readOnly(tools: ["calculator"]))
        let verdict = await subject.decide(
            tool: "calculator",
            arguments: "{}",
            conversationID: "conv-1",
            provenance: .untrusted(source: "kb-article#88")
        )
        guard case let .denied(refusal) = verdict else {
            Issue.record("expected .denied, got \(verdict)")
            return
        }
        #expect(refusal.explanation.contains("untrusted(kb-article#88)"))
        #expect(refusal.explanation.contains("admits at most model"))
    }

    /// "Approve calculator" on an exhausted lease would be a button that cannot work.
    @Test("an exhausted grant offers a fresh conversation rather than an approval that cannot help")
    func exhaustedGrant() async {
        let subject = gate(ToolAuthorityGate.readOnly(tools: ["calculator"]), maxToolUses: 1)
        _ = await subject.decide(
            tool: "calculator", arguments: "{}",
            conversationID: "conv-1", provenance: .modelAuthored
        )
        let verdict = await subject.decide(
            tool: "calculator", arguments: "{}",
            conversationID: "conv-1", provenance: .modelAuthored
        )
        guard case let .denied(refusal) = verdict else {
            Issue.record("expected .denied, got \(verdict)")
            return
        }
        #expect(refusal.recovery == .shortenConversation)
        #expect(refusal.explanation.contains("spent all 1 of its uses"))
    }

    @Test("a capability that demands a signature asks for one instead of denying or allowing")
    func approvalRequired() async {
        // `.read` has to be in the set: the gate proposes every tool call as a read, so a
        // capability that only granted `.externalSend` would be denied for the action rather than
        // reaching the approval branch at all.
        let supervised = Capability(
            tool: ToolName("send_email"),
            actions: [.read, .externalSend],
            scope: .subtree(ResourcePath("tools/send_email")),
            maxProvenance: .modelAuthored,
            requiresApproval: true
        )
        let verdict = await gate([supervised]).decide(
            tool: "send_email",
            arguments: #"{"to":"a@b.test"}"#,
            conversationID: "conv-1",
            provenance: .modelAuthored
        )
        guard case let .approvalRequired(refusal) = verdict else {
            Issue.record("expected .approvalRequired, got \(verdict)")
            return
        }
        #expect(refusal.headline == "Approval needed")
        #expect(refusal.recovery == .approveTool(name: "send_email"))
        #expect(refusal.explanation.contains("a@b.test"), "an approver has to see the arguments")
    }

    @Test("a principal with no grant at all is denied before any capability is consulted")
    func noGrants() async {
        let subject = gate([])
        let verdict = await subject.decide(
            tool: "calculator", arguments: "{}",
            conversationID: "conv-9", provenance: .modelAuthored
        )
        guard case let .denied(refusal) = verdict else {
            Issue.record("expected .denied, got \(verdict)")
            return
        }
        #expect(refusal.explanation.contains("holds no grants"))
    }

    @Test("closing a conversation revokes its grant, and closing twice is not an error")
    func closing() async {
        let subject = gate(ToolAuthorityGate.readOnly(tools: ["calculator"]))
        _ = await subject.decide(
            tool: "calculator", arguments: "{}",
            conversationID: "conv-1", provenance: .modelAuthored
        )
        await subject.close(conversationID: "conv-1")
        await subject.close(conversationID: "conv-1")

        let statistics = await subject.statistics()
        #expect(statistics.grantsIssued == 1)
        #expect(statistics.grantsRevoked == 1)
        #expect(statistics.allowed == 1)

        let trail = await subject.trail()
        #expect(trail.contains(.grantRevoked(id: "conv-conv-1")))
    }

    @Test("the read-only capability set grants observation and nothing else")
    func readOnlyShape() {
        let capabilities = ToolAuthorityGate.readOnly(tools: ["calculator", "current_time"])
        #expect(capabilities.count == 2)
        for capability in capabilities {
            #expect(capability.actions == [.read])
            #expect(capability.maxProvenance == .modelAuthored)
            #expect(!capability.requiresApproval)
            #expect(capability.scope.admits(ResourcePath("tools/\(capability.tool.raw)")))
            #expect(!capability.scope.admits(ResourcePath("tools")))
        }
    }
}

@Suite("Tool call provenance")
struct ToolCallContextTests {
    @Test("a turn with no retrieved sources is model-authored, not untrusted")
    func noSources() {
        let context = ToolCallContext.forTurn(conversationID: "c", sources: [])
        #expect(context.provenance == .modelAuthored)
    }

    /// Naming the passage matters: the refusal that follows quotes it back to the user.
    @Test("a turn built on retrieval is untrusted, named for the passage that ranked highest")
    func withSources() {
        let context = ToolCallContext.forTurn(
            conversationID: "c",
            sources: [
                RetrievedSource(id: "kb-88", title: "t", snippet: "s", relevancePercent: 90),
                RetrievedSource(id: "kb-12", title: "t", snippet: "s", relevancePercent: 40)
            ]
        )
        #expect(context.provenance == .untrusted(source: "kb-88"))
    }
}
