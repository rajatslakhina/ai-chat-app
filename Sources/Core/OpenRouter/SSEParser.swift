import Foundation

/// One decoded Server-Sent Events frame.
enum SSEFrame: Sendable, Equatable {
    /// A `data:` payload, with the prefix and one optional leading space stripped.
    case data(String)
    /// The `[DONE]` sentinel that ends an OpenAI-style stream.
    case done
}

/// Turns an SSE byte stream into frames, one line at a time.
///
/// Written as a fed-line state machine rather than a regex over the whole body because the whole
/// body does not exist yet — that is the point of streaming. Keeping it pure and synchronous also
/// means the framing can be tested against captured bytes without a network or a clock.
///
/// The rules implemented here were taken from a real captured OpenRouter stream, not from a spec
/// reading:
///
/// - `: OPENROUTER PROCESSING` — a comment line. OpenRouter sends these as keep-alives while an
///   upstream provider is still thinking. Any line beginning with `:` is a comment per the SSE
///   spec and must be skipped. Feeding one to `JSONDecoder` is a decode error on every keep-alive,
///   which reads as a broken stream when nothing is wrong.
/// - `data: {...}` — one JSON chunk. Multiple `data:` lines before a blank line concatenate with
///   newlines, per the spec, even though OpenRouter currently sends one.
/// - `data: [DONE]` — terminator. Not JSON; decoding it throws.
/// - A blank line dispatches the accumulated event.
struct SSEParser {
    private var buffer: [String] = []

    /// Feeds one line and returns a frame if that line completed one.
    mutating func feed(_ line: String) -> SSEFrame? {
        // A blank line terminates the current event.
        if line.isEmpty {
            return flush()
        }
        // Comments (keep-alives) are skipped entirely.
        if line.hasPrefix(":") {
            return nil
        }
        guard let separator = line.firstIndex(of: ":") else {
            // A bare field name with no value carries nothing this client needs.
            return nil
        }
        let field = String(line[line.startIndex..<separator])
        guard field == "data" else { return nil }

        var value = String(line[line.index(after: separator)...])
        // Exactly one leading space after the colon is part of the framing, not the payload.
        if value.hasPrefix(" ") { value.removeFirst() }
        buffer.append(value)
        return nil
    }

    /// Emits whatever has accumulated. Called on a blank line, and once at end of stream for a
    /// final event that arrived without its trailing blank line.
    mutating func flush() -> SSEFrame? {
        guard !buffer.isEmpty else { return nil }
        let payload = buffer.joined(separator: "\n")
        buffer.removeAll()
        let trimmed = payload.trimmingCharacters(in: .whitespaces)
        if trimmed == "[DONE]" { return .done }
        if trimmed.isEmpty { return nil }
        return .data(trimmed)
    }

    /// Convenience for tests and for parsing a captured body in one go.
    static func frames(in text: String) -> [SSEFrame] {
        var parser = SSEParser()
        var frames: [SSEFrame] = []
        // CRLF is normalised *before* splitting, and that ordering is the whole point: in Swift
        // "\r\n" is a single extended grapheme cluster, so `split(separator: "\n")` does not match
        // it at all and a CRLF stream comes back as one un-split blob.
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        // `omittingEmptySubsequences: false` matters too: blank lines are the event delimiter, so
        // dropping them would merge every chunk in the stream into a single event.
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if let frame = parser.feed(String(line)) { frames.append(frame) }
        }
        if let trailing = parser.flush() { frames.append(trailing) }
        return frames
    }
}

/// Splits a byte stream into lines without depending on `AsyncLineSequence`'s treatment of blank
/// lines.
///
/// SSE uses the blank line as its event delimiter, so whether the line sequence preserves or
/// swallows empty lines decides whether the framing works at all. Rather than depend on that
/// behaviour, this accumulates bytes and cuts on `\n` itself, stripping a trailing `\r`.
struct SSELineAccumulator {
    private var pending: [UInt8] = []

    /// Appends one byte, returning a completed line when it terminates one.
    mutating func feed(_ byte: UInt8) -> String? {
        guard byte == 0x0A else {
            pending.append(byte)
            return nil
        }
        if pending.last == 0x0D { pending.removeLast() }
        // Non-failable on purpose: the failable initializer returns nil for the whole line if a
        // single byte is invalid UTF-8, which would silently drop a chunk of the answer. Replacing
        // the bad byte degrades one character instead of losing the frame.
        // swiftlint:disable:next optional_data_string_conversion
        let line = String(decoding: pending, as: UTF8.self)
        pending.removeAll(keepingCapacity: true)
        return line
    }

    /// Whatever remains after the last newline — a final line with no trailing newline.
    mutating func drain() -> String? {
        guard !pending.isEmpty else { return nil }
        if pending.last == 0x0D { pending.removeLast() }
        // Same reasoning as `feed`: degrade one character rather than drop the final frame.
        // swiftlint:disable:next optional_data_string_conversion
        let line = String(decoding: pending, as: UTF8.self)
        pending.removeAll(keepingCapacity: true)
        return line
    }
}
