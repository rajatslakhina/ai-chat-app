import Foundation
import Testing
@testable import AIChatApp

/// A fixed calendar and a fixed `now`, so none of these assertions depend on the machine's clock,
/// its time zone, or what time of day the suite happens to run.
private enum Clock {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    /// 2 August 2026, 15:00 UTC. Verified rather than assumed — the first value picked here was
    /// a day out, and every "Yesterday" assertion quietly agreed with it.
    static let now = Date(timeIntervalSince1970: 1_785_682_800)

    static func ago(_ seconds: Double) -> Date { now.addingTimeInterval(-seconds) }
}

@Suite("Relative time")
struct RelativeTimeTests {
    private func label(_ date: Date) -> String {
        RelativeTime.label(for: date, now: Clock.now, calendar: Clock.calendar)
    }

    @Test("the present moment reads as Now rather than a number that ticks while you look at it")
    func immediate() {
        #expect(label(Clock.now) == "Now")
        #expect(label(Clock.ago(4)) == "Now")
    }

    @Test("a clock that ran backwards still reads as Now")
    func future() {
        // Reachable without anything being broken: the device's time changed, or a timestamp came
        // from a machine a second ahead. "In -3 seconds" is not something to show anyone.
        #expect(label(Clock.now.addingTimeInterval(30)) == "Now")
    }

    @Test("seconds, then minutes, then hours")
    func units() {
        #expect(label(Clock.ago(5)) == "5 seconds ago")
        #expect(label(Clock.ago(59)) == "59 seconds ago")
        #expect(label(Clock.ago(60)) == "1 minute ago")
        #expect(label(Clock.ago(90)) == "1 minute ago", "rounded down, not up")
        #expect(label(Clock.ago(120)) == "2 minutes ago")
        #expect(label(Clock.ago(3_599)) == "59 minutes ago")
        #expect(label(Clock.ago(3_600)) == "1 hour ago")
        #expect(label(Clock.ago(7_200)) == "2 hours ago")
        #expect(label(Clock.ago(86_399)) == "23 hours ago")
    }

    @Test("one is singular")
    func singular() {
        // "1 minutes ago" is the kind of thing nobody files a bug for and everybody notices.
        #expect(label(Clock.ago(60)) == "1 minute ago")
        #expect(label(Clock.ago(3_600)) == "1 hour ago")
    }

    @Test("past a day it becomes a clock time, because the day heading says which day")
    func crossesOverAtADay() {
        let yesterday = label(Clock.ago(86_400))
        #expect(!yesterday.contains("ago"), "a duration stops being useful here: \(yesterday)")
        #expect(
            yesterday.contains("3:00") || yesterday.contains("15:00"),
            "expected a clock time, got \(yesterday)"
        )
    }

    @Test("the long form names the day, for somewhere with no heading above it")
    func detailed() {
        let detailed = { (date: Date) in
            RelativeTime.detailed(for: date, now: Clock.now, calendar: Clock.calendar)
        }
        #expect(detailed(Clock.ago(120)) == "2 minutes ago", "under a day it is still a duration")
        #expect(detailed(Clock.ago(86_400)).hasPrefix("Yesterday at "))
        #expect(detailed(Clock.ago(86_400 * 5)).contains("2026"))
    }
}

@Suite("Day sections")
struct DaySectionTests {
    private func title(_ date: Date) -> String {
        DaySection.title(for: date, now: Clock.now, calendar: Clock.calendar)
    }

    @Test("today, yesterday, and then the full date")
    func titles() {
        #expect(title(Clock.now) == "Today")
        #expect(title(Clock.ago(3_600)) == "Today")
        #expect(title(Clock.ago(86_400)) == "Yesterday")
        #expect(title(Clock.ago(86_400 * 3)) == "July 30, 2026")
    }

    @Test("the day is a calendar day, not a 24-hour window")
    func calendarDayNotElapsedHours() {
        // 23:30 yesterday, read at 15:00 today: 15 hours ago, but plainly not today. Grouping on
        // elapsed hours would file it under Today and stop matching what a person remembers.
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 1
        components.hour = 23
        components.minute = 30
        let lateLastNight = Clock.calendar.date(from: components)
        #expect(title(lateLastNight ?? Clock.now) == "Yesterday")
    }

    @Test("grouping keeps the order it was given and never merges non-adjacent days")
    func grouping() {
        let dates = [
            Clock.ago(60),
            Clock.ago(3_600),
            Clock.ago(86_400),
            Clock.ago(86_400 * 3)
        ]
        let groups = DaySection.group(dates, now: Clock.now, calendar: Clock.calendar) { $0 }

        #expect(groups.map(\.title) == ["Today", "Yesterday", "July 30, 2026"])
        #expect(groups.map(\.items.count) == [2, 1, 1])
        // The caller sorts; the grouper must not re-sort, or the chat list would start jumping.
        #expect(groups.flatMap(\.items) == dates)
    }

    @Test("an empty list produces no headings rather than an empty one")
    func empty() {
        let groups = DaySection.group([Date](), now: Clock.now, calendar: Clock.calendar) { $0 }
        #expect(groups.isEmpty)
    }
}

/// The device's zone, not the server's.
///
/// A `Date` is an absolute instant, so a timestamp written by a server in UTC and one written on
/// the device are the same kind of value — the conversion is entirely a question of which calendar
/// renders it. These assert that a single instant reads as a different wall-clock time in two
/// zones, and as a different *day* where the zone pushes it across midnight.
@Suite("Rendered in the device's time zone")
struct TimeZoneConversionTests {
    private func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier) ?? .gmt
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    /// 2 August 2026, 15:00 UTC — as a server would send it.
    private let instant = Date(timeIntervalSince1970: 1_785_682_800)

    @Test("one instant reads as a different clock time in each zone")
    func clockTimeShifts() {
        let utc = RelativeTime.time(of: instant, calendar: calendar("UTC"))
        let india = RelativeTime.time(of: instant, calendar: calendar("Asia/Kolkata"))
        let newYork = RelativeTime.time(of: instant, calendar: calendar("America/New_York"))

        #expect(utc.contains("3:00") || utc.contains("15:00"), "utc was \(utc)")
        // +05:30 from 15:00 UTC is 20:30 local.
        #expect(india.contains("8:30") || india.contains("20:30"), "india was \(india)")
        // -04:00 in August is 11:00 local.
        #expect(newYork.contains("11:00"), "newYork was \(newYork)")
    }

    @Test("a zone that pushes an instant over midnight changes the day it is filed under")
    func dayShifts() {
        // 22:00 UTC on 2 August is already 03:30 on 3 August in Kolkata. Filing it under the
        // server's day rather than the device's is how a chat sent "today" lands under Yesterday.
        let lateUTC = Date(timeIntervalSince1970: 1_785_708_000)
        let readAt = Date(timeIntervalSince1970: 1_785_729_600)

        let utcTitle = DaySection.title(for: lateUTC, now: readAt, calendar: calendar("UTC"))
        let indiaTitle = DaySection.title(
            for: lateUTC,
            now: readAt,
            calendar: calendar("Asia/Kolkata")
        )
        #expect(utcTitle != indiaTitle, "the zone decides the day: \(utcTitle) vs \(indiaTitle)")
    }

    @Test("the production entry points read the device calendar rather than a pinned zone")
    func defaultsToDevice() {
        // The defaulted parameter is the whole conversion. If it were ever pinned to UTC, every
        // timestamp outside that zone would be silently wrong and nothing else here would notice.
        #expect(
            RelativeTime.label(for: Date()) == RelativeTime.label(for: Date(), calendar: .current)
        )
        #expect(Calendar.current.timeZone == TimeZone.current)
    }
}
