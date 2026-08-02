import Foundation
import StructuredOutputKit
import ToolRegistryKit

/// Why a tool refused the arguments it was handed.
///
/// Reachable only if a tool is registered with a schema that does not match its handler, because
/// `ToolRegistry` validates against the declared `JSONSchema` before the handler ever runs. It
/// exists so that mismatch surfaces as a sentence rather than as a crash.
enum ToolArgumentError: Error, Equatable, CustomStringConvertible {
    case missingString(field: String)

    var description: String {
        switch self {
        case let .missingString(field):
            return "the \"\(field)\" argument was missing or was not a string"
        }
    }
}

/// Why the clock tool could not answer.
enum ClockToolError: Error, Equatable, CustomStringConvertible {
    case unknownTimeZone(String)

    var description: String {
        switch self {
        case let .unknownTimeZone(identifier):
            return "\"\(identifier)\" is not an IANA time zone identifier"
        }
    }
}

/// The tools this app registers with `ToolRegistryKit`.
///
/// Both do real work. A calculator that returned a canned number and a clock that returned a fixed
/// string would exercise the same wiring, and would also make every test that passes meaningless —
/// the interesting failures in a tool round trip are the ones where the tool genuinely computes
/// something the model then has to read back.
///
/// Both are `.read` actions in `ToolAuthorityKit`'s vocabulary: neither changes state, deletes
/// anything, or moves data outside the trust boundary. Declaring them as anything more severe
/// would make the authority layer's severity ordering meaningless.
enum DemoTools {
    static let calculatorName = "calculator"
    static let clockName = "current_time"

    static let calculator = ToolDefinition(
        name: calculatorName,
        description: """
            Evaluates an arithmetic expression and returns its exact numeric result. \
            Supports + - * / , parentheses and unary minus. \
            Use this rather than doing arithmetic yourself.
            """,
        parameters: .object(
            properties: [
                "expression": .string(
                    description: "The expression to evaluate, for example \"(3 + 4) * 12\"."
                )
            ],
            required: ["expression"]
        )
    )

    /// Registered with an empty `required` list on purpose: OpenRouter routinely sends
    /// `"arguments": ""` for a call with no arguments, and a schema that demanded a key would turn
    /// every such call into `.invalidArguments` before the handler ever ran.
    static let currentTime = ToolDefinition(
        name: clockName,
        description: """
            Returns the current date and time, optionally in a named IANA time zone. \
            Use this rather than guessing what today's date is.
            """,
        parameters: .object(
            properties: [
                "timeZone": .string(
                    description: "IANA identifier such as \"Asia/Kolkata\". Defaults to UTC."
                )
            ],
            required: []
        )
    )

    static func calculatorHandler() -> ClosureToolHandler {
        ClosureToolHandler { arguments in
            guard case let .object(fields) = arguments,
                  case let .string(expression)? = fields["expression"] else {
                throw ToolArgumentError.missingString(field: "expression")
            }
            return .object([
                "expression": .string(expression),
                "result": .number(try ArithmeticEvaluator.evaluate(expression))
            ])
        }
    }

    /// `now` is injected so a test can assert on an exact instant. Reading the clock inside the
    /// closure would make every assertion about this tool either trivial or flaky.
    static func currentTimeHandler(
        now: @escaping @Sendable () -> Date = Date.init
    ) -> ClosureToolHandler {
        ClosureToolHandler { arguments in
            let zone = try timeZone(named: requestedZone(in: arguments))
            let instant = now()
            return .object([
                "timeZone": .string(zone.identifier),
                "iso8601": .string(iso8601(instant, in: zone)),
                "readable": .string(readable(instant, in: zone)),
                "unixSeconds": .number(instant.timeIntervalSince1970.rounded(.down))
            ])
        }
    }

    private static func requestedZone(in arguments: JSONValue) -> String? {
        guard case let .object(fields) = arguments,
              case let .string(identifier)? = fields["timeZone"] else { return nil }
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func timeZone(named identifier: String?) throws -> TimeZone {
        guard let identifier else { return .gmt }
        guard let zone = TimeZone(identifier: identifier) else {
            throw ClockToolError.unknownTimeZone(identifier)
        }
        return zone
    }

    private static func iso8601(_ date: Date, in zone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = zone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// `en_US_POSIX` rather than the device locale: this string is read by a model, not by the
    /// user, and a format that changes with the phone's region settings changes the prompt bytes
    /// for no reason — which also defeats OpenRouter's prompt caching.
    private static func readable(_ date: Date, in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "EEEE d MMMM yyyy 'at' HH:mm"
        return formatter.string(from: date)
    }
}
