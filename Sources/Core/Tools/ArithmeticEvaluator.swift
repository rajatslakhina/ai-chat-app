import Foundation

/// Why the calculator tool could not evaluate an expression.
///
/// `CustomStringConvertible` is not decoration here. `ToolRegistry` renders a thrown handler error
/// with plain `"\(error)"` interpolation and never consults `LocalizedError`, so a bare `struct`
/// would reach the model — and the Diagnostics row — as `MalformedExpression()`, and an `NSError`
/// would arrive as a full `Error Domain=… UserInfo={…}` dump. Owning the string here is what keeps
/// a handler failure readable and keeps anything incidental out of it.
enum ArithmeticError: Error, Equatable, CustomStringConvertible {
    case empty
    case unexpectedEnd
    case unexpectedCharacter(Character, at: Int)
    case unbalancedParenthesis
    case dividedByZero
    case notFinite

    var description: String {
        switch self {
        case .empty:
            return "the expression was empty"
        case .unexpectedEnd:
            return "the expression ended before it was complete"
        case let .unexpectedCharacter(character, index):
            return "unexpected character '\(character)' at position \(index)"
        case .unbalancedParenthesis:
            return "the parentheses are unbalanced"
        case .dividedByZero:
            return "division by zero"
        case .notFinite:
            return "the result is not a finite number"
        }
    }
}

/// Evaluates the four arithmetic operations with correct precedence.
///
/// A real recursive-descent parser rather than a lookup table of canned answers: a tool that only
/// pretends to work teaches nothing about the round trip, and the first question a reviewer asks a
/// demo tool is whether it actually computes. Whitespace is stripped up front so the grammar
/// functions never have to interleave a `skipSpaces` call, which is where hand-written parsers
/// usually acquire their off-by-one bugs.
enum ArithmeticEvaluator {
    static func evaluate(_ text: String) throws -> Double {
        let characters = Array(text.filter { !$0.isWhitespace })
        guard !characters.isEmpty else { throw ArithmeticError.empty }

        var parser = Parser(characters)
        let value = try parser.expression()
        try parser.expectEnd()
        guard value.isFinite else { throw ArithmeticError.notFinite }
        return value
    }

    private struct Parser {
        private let characters: [Character]
        private var index = 0

        init(_ characters: [Character]) {
            self.characters = characters
        }

        /// `term (('+' | '-') term)*`
        mutating func expression() throws -> Double {
            var value = try term()
            while let symbol = peek(), symbol == "+" || symbol == "-" {
                advance()
                let right = try term()
                value = symbol == "+" ? value + right : value - right
            }
            return value
        }

        /// `factor (('*' | '/') factor)*` — binding tighter than `expression`, which is the whole
        /// reason the grammar has two levels rather than one left-to-right scan.
        mutating func term() throws -> Double {
            var value = try factor()
            while let symbol = peek(), Self.multiplying.contains(symbol) {
                advance()
                let right = try factor()
                if symbol == "*" || symbol == "×" {
                    value *= right
                } else {
                    guard right != 0 else { throw ArithmeticError.dividedByZero }
                    value /= right
                }
            }
            return value
        }

        /// `('+' | '-')? ( '(' expression ')' | number )`
        mutating func factor() throws -> Double {
            guard let symbol = peek() else { throw ArithmeticError.unexpectedEnd }
            switch symbol {
            case "-":
                advance()
                return try -factor()
            case "+":
                advance()
                return try factor()
            case "(":
                advance()
                let value = try expression()
                guard peek() == ")" else { throw ArithmeticError.unbalancedParenthesis }
                advance()
                return value
            default:
                return try number()
            }
        }

        private mutating func number() throws -> Double {
            let start = index
            while let symbol = peek(), symbol.isNumber || symbol == "." {
                advance()
            }
            guard start < index, let value = Double(String(characters[start..<index])) else {
                guard let symbol = peek() else { throw ArithmeticError.unexpectedEnd }
                throw ArithmeticError.unexpectedCharacter(symbol, at: start)
            }
            return value
        }

        func expectEnd() throws {
            guard let symbol = peek() else { return }
            throw ArithmeticError.unexpectedCharacter(symbol, at: index)
        }

        private func peek() -> Character? {
            index < characters.count ? characters[index] : nil
        }

        private mutating func advance() {
            index += 1
        }

        /// `×` and `÷` are here because models emit them: a model asked to multiply frequently
        /// writes the typographic sign, and rejecting it would look like the calculator is broken.
        private static let multiplying: Set<Character> = ["*", "/", "×", "÷"]
    }
}
