import Foundation

/// How long ago something happened, in the words a chat list uses.
///
/// Deliberately not `Text(date, format: .relative)`. SwiftUI's relative style says "1 min. ago"
/// and, past a day, "2 days ago" — it never crosses over to a clock time, and it abbreviates in
/// ways that read oddly next to a day heading that already says "Yesterday".
///
/// `now` and `calendar` are parameters rather than reads of the ambient clock, because every one
/// of these strings is asserted somewhere: a helper that called `Date()` internally could only be
/// tested by sleeping.
///
/// **Time zone.** A `Date` is an absolute instant with no zone of its own, so a timestamp written
/// on a server in UTC and one written on the device are the same kind of value. Every string here
/// is rendered through `calendar.timeZone`, which defaults to `Calendar.current` — the device's
/// zone. That is the conversion: nothing is stored shifted, and nothing is displayed unshifted.
enum RelativeTime {
    /// Under this, "Now" reads better than a number that changes while you look at it.
    static let momentSeconds = 5.0

    /// The point at which a duration stops being useful and a clock time takes over.
    static let daySeconds = 86_400.0

    /// The short form, for a row that already sits under a day heading.
    ///
    /// Once something is a day old the heading says which day, so the row only has to say when —
    /// "3:43 PM" is more use there than "2 days ago".
    static func label(
        for date: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let elapsed = now.timeIntervalSince(date)
        // A negative interval means the clock moved backwards or the device's time changed. "In
        // -3 seconds" is nonsense to show anyone, so it reads as the present moment.
        guard elapsed >= momentSeconds else { return "Now" }
        guard elapsed < daySeconds else { return time(of: date, calendar: calendar) }

        if elapsed < 60 {
            return counted(Int(elapsed), "second")
        }
        if elapsed < 3_600 {
            return counted(Int(elapsed / 60), "minute")
        }
        return counted(Int(elapsed / 3_600), "hour")
    }

    /// The long form, for somewhere with no day heading to lean on.
    static func detailed(
        for date: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let elapsed = now.timeIntervalSince(date)
        guard elapsed >= daySeconds else {
            return label(for: date, now: now, calendar: calendar)
        }
        let day = DaySection.title(for: date, now: now, calendar: calendar)
        return "\(day) at \(time(of: date, calendar: calendar))"
    }

    /// "1 minute ago", not "1 minutes ago".
    private static func counted(_ value: Int, _ unit: String) -> String {
        "\(value) \(unit)\(value == 1 ? "" : "s") ago"
    }

    /// The clock time, in the calendar's zone — the device's, unless a test says otherwise.
    static func time(of date: Date, calendar: Calendar) -> String {
        var formatted = Date.FormatStyle(date: .omitted, time: .shortened)
        formatted.calendar = calendar
        formatted.timeZone = calendar.timeZone
        return date.formatted(formatted)
    }
}

/// The heading a conversation belongs under.
enum DaySection {
    /// "Today", "Yesterday", or the full date for anything older.
    ///
    /// Compared by calendar day rather than by elapsed hours: something sent at 11pm is
    /// "Yesterday" at 1am the next morning, two hours later, and calling that "Today" because
    /// fewer than 24 hours passed is how a list stops matching what a person remembers.
    static func title(
        for date: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        var formatted = Date.FormatStyle(date: .long, time: .omitted)
        formatted.calendar = calendar
        formatted.timeZone = calendar.timeZone
        // Month, day, year — pinned rather than inherited. `.long` follows the locale, which on a
        // UK-formatted device renders "31 July 2026"; the ordering asked for here is the US one,
        // and this is the single string in the app that overrides the device's preference. The
        // zone is still the device's, which is the part that would actually mislead if it were
        // wrong.
        formatted.locale = Locale(identifier: "en_US")
        return date.formatted(formatted)
    }

    /// Splits an already-sorted list into day groups, keeping the order it arrived in.
    ///
    /// Sorting here instead would silently override the caller's ordering — the chat list is
    /// newest-first by `updatedAt`, and a re-sort inside a formatting helper is the kind of thing
    /// that is only noticed once the list starts jumping.
    static func group<Item>(
        _ items: [Item],
        now: Date = Date(),
        calendar: Calendar = .current,
        by date: (Item) -> Date
    ) -> [(title: String, items: [Item])] {
        var groups: [(title: String, items: [Item])] = []
        for item in items {
            let title = self.title(for: date(item), now: now, calendar: calendar)
            if let index = groups.indices.last, groups[index].title == title {
                groups[index].items.append(item)
            } else {
                groups.append((title: title, items: [item]))
            }
        }
        return groups
    }
}
