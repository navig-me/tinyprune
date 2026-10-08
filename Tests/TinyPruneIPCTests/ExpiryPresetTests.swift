import Testing
import Foundation
@testable import TinyPruneIPC

@Suite struct ExpiryPresetTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    @Test func tonightIsTodayAt2359WhenStillAhead() {
        let now = date(2026, 10, 8, 10, 0)
        #expect(ExpiryPreset.tonight.date(from: now, calendar: calendar) == date(2026, 10, 8, 23, 59))
        let earlyMorning = date(2026, 10, 8, 0, 30)
        #expect(ExpiryPreset.tonight.date(from: earlyMorning, calendar: calendar) == date(2026, 10, 8, 23, 59))
    }

    @Test func tonightRollsToTomorrow2359AtOrAfter2359() {
        let expected = date(2026, 10, 9, 23, 59)
        #expect(ExpiryPreset.tonight.date(from: date(2026, 10, 8, 23, 59), calendar: calendar) == expected)
        #expect(ExpiryPreset.tonight.date(from: date(2026, 10, 8, 23, 59, 30), calendar: calendar) == expected)
    }

    @Test func tonightAcrossMonthEnd() {
        let now = date(2026, 12, 31, 23, 59, 45)
        #expect(ExpiryPreset.tonight.date(from: now, calendar: calendar) == date(2027, 1, 1, 23, 59))
    }

    @Test func tomorrowAndDayPresetsUseCalendarDays() {
        let now = date(2026, 10, 8, 10, 0)
        #expect(ExpiryPreset.tomorrow.date(from: now, calendar: calendar) == date(2026, 10, 9, 10, 0))
        #expect(ExpiryPreset.days(7).date(from: now, calendar: calendar) == date(2026, 10, 15, 10, 0))
        #expect(ExpiryPreset.days(30).date(from: now, calendar: calendar) == date(2026, 11, 7, 10, 0))
        #expect(ExpiryPreset.weeks(2).date(from: now, calendar: calendar) == date(2026, 10, 22, 10, 0))
    }

    @Test func dayPresetsFollowWallClockAcrossDaylightSaving() {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let now = newYork.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 12))!
        let expected = newYork.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!
        #expect(ExpiryPreset.tomorrow.date(from: now, calendar: newYork) == expected)
        #expect(ExpiryPreset.days(1).date(from: now, calendar: newYork) == expected)
    }

    @Test func shortUnitsAreExactIntervals() {
        let now = date(2026, 10, 8, 10, 0)
        #expect(ExpiryPreset.minutes(30).date(from: now, calendar: calendar) == now.addingTimeInterval(1_800))
        #expect(ExpiryPreset.hours(12).date(from: now, calendar: calendar) == now.addingTimeInterval(43_200))
    }

    @Test func everyPresetIsStrictlyInTheFuture() {
        let now = date(2026, 10, 8, 23, 59)
        for preset in [ExpiryPreset.tonight, .tomorrow, .minutes(1), .hours(1), .days(1), .weeks(1)] {
            #expect(preset.date(from: now, calendar: calendar) > now)
        }
    }

    @Test func parsesDocumentedSyntax() {
        #expect(ExpiryPreset(parsing: "tonight") == .tonight)
        #expect(ExpiryPreset(parsing: "Tomorrow") == .tomorrow)
        #expect(ExpiryPreset(parsing: "7d") == .days(7))
        #expect(ExpiryPreset(parsing: "12H") == .hours(12))
        #expect(ExpiryPreset(parsing: "30m") == .minutes(30))
        #expect(ExpiryPreset(parsing: "2w") == .weeks(2))
    }

    @Test func rejectsMalformedOrUnboundedInput() {
        for text in ["", "d", "0d", "-3d", "1.5h", "7", "7x", "tonite", "99999999999999999999d", "9999999999d", "/tmp/file"] {
            #expect(ExpiryPreset(parsing: text) == nil, "\(text) should not parse")
        }
    }

    @Test func menuTitlesAreStable() {
        #expect(ExpiryPreset.tonight.title == "Tonight")
        #expect(ExpiryPreset.days(7).title == "7 Days")
        #expect(ExpiryPreset.days(1).title == "1 Day")
    }
}
