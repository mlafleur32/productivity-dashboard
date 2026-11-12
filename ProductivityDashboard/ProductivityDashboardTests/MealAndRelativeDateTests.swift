//
//  MealAndRelativeDateTests.swift
//  ProductivityDashboardTests
//
//  Stage 8, Step D2 (Matt, 2026-09-17):
//    - meal words use the Event Suggestions preferences for time and length
//      (an explicit time in the email wins);
//    - relative dates ("tomorrow", "Friday") are counted from when the email
//      was SENT, and a notice appears only if that day has already passed.
//  Uses the Mac's current calendar/time zone, like NSDataDetector does.
//  Synthetic text only.
//

import Testing
import Foundation
@testable import ProductivityDashboard

@MainActor
struct MealAndRelativeDateTests {

    let cal = Calendar.current

    /// Wednesday, March 10, 2027 at 9:15 AM (local).
    var sent: Date { cal.date(from: DateComponents(year: 2027, month: 3, day: 10, hour: 9, minute: 15))! }

    private func day(_ offset: Int, hour: Int = 0, minute: Int = 0) -> Date {
        let base = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: sent))!
        return cal.date(bySettingHour: hour, minute: minute, second: 0, of: base)!
    }

    private func suggest(subject: String = "Catch up", body: String?, sentAt: Date? = nil,
                         now: Date? = nil, meals: MealPreferences = .defaults)
        -> (values: NewEventFormValues, found: Bool, notice: String?)? {
        let message = MailMessage(id: "m", fromName: "Pat", fromAddress: "pat@example.com",
                                  subject: subject, date: sentAt ?? sent,
                                  authentication: AuthenticationResults(spf: .pass, dkim: .pass, dmarc: .pass))
        let result = EventSuggester.suggest(for: message, body: body, localCategory: .other,
                                            cloudVerdict: nil, defaultCalendarID: "cal",
                                            meals: meals, now: now ?? sentAt ?? sent, calendar: cal)
        guard case .suggestion(let v, let found, let notice) = result else {
            Issue.record("expected suggestion, got \(result)")
            return nil
        }
        return (v, found, notice)
    }

    // MARK: - Classification

    struct RelCase: Sendable, CustomTestStringConvertible {
        let text: String
        let expected: RelativeDay
        var testDescription: String { text }
    }

    nonisolated static let relCases: [RelCase] = [
        .init(text: "tomorrow", expected: .offset(days: 1, word: "tomorrow")),
        .init(text: "Tomorrow at 3pm", expected: .offset(days: 1, word: "tomorrow")),
        .init(text: "the day after tomorrow", expected: .offset(days: 2, word: "the day after tomorrow")),
        .init(text: "tonight", expected: .offset(days: 0, word: "tonight")),
        .init(text: "today at noon", expected: .offset(days: 0, word: "today")),
        .init(text: "this evening", expected: .offset(days: 0, word: "today")),
        .init(text: "Friday", expected: .weekday(6, word: "Friday")),
        .init(text: "next Tuesday", expected: .weekday(3, word: "Tuesday")),
        .init(text: "Thurs 2pm", expected: .weekday(5, word: "Thursday")),
        .init(text: "Friday, October 15", expected: .absolute),
        .init(text: "10/15", expected: .absolute),
        .init(text: "October 15, 2027 at 3:00 PM", expected: .absolute),
    ]

    @Test("Relative vs absolute date text", arguments: relCases)
    func classification(_ c: RelCase) {
        #expect(EventSuggester.relativeDay(in: c.text) == c.expected)
    }

    struct MealCase: Sendable, CustomTestStringConvertible {
        let text: String
        let meal: Meal?
        var testDescription: String { text }
    }

    nonisolated static let mealCases: [MealCase] = [
        .init(text: "Lunch tomorrow?", meal: .lunch),
        .init(text: "want to grab brunch", meal: .breakfast),
        .init(text: "Supper at our place", meal: .dinner),
        .init(text: "Dinner or lunch, your call", meal: .dinner),
        .init(text: "launch party next week", meal: nil),
        .init(text: "no meals here", meal: nil),
    ]

    @Test("Meal words", arguments: mealCases)
    func meals(_ c: MealCase) {
        #expect(EventSuggester.detectMeal(in: c.text) == c.meal)
    }

    // MARK: - Anchoring to the sent date

    @Test("Relative days count from the sent day; weekdays mean the next one after it")
    func anchoring() {
        let found = DetectedEventTime(start: .distantFuture, duration: 0, hasTime: false)
        let sentDay = cal.startOfDay(for: sent)   // Wednesday
        #expect(EventSuggester.anchoredDay(for: found, kind: .offset(days: 1, word: "tomorrow"), sentDay: sentDay, calendar: cal) == day(1))
        #expect(EventSuggester.anchoredDay(for: found, kind: .weekday(6, word: "Friday"), sentDay: sentDay, calendar: cal) == day(2))
        #expect(EventSuggester.anchoredDay(for: found, kind: .weekday(4, word: "Wednesday"), sentDay: sentDay, calendar: cal) == day(7))
        #expect(EventSuggester.anchoredDay(for: found, kind: .weekday(2, word: "Monday"), sentDay: sentDay, calendar: cal) == day(5))
    }

    // MARK: - Meal preferences applied

    @Test("“Lunch tomorrow”, read the same day → tomorrow at 12:00 PM for 1 hour, no notice")
    func lunchTomorrowSameDay() throws {
        let r = try #require(suggest(body: "Want to do lunch tomorrow?"))
        #expect(r.found)
        #expect(!r.values.isAllDay)
        #expect(r.values.start == day(1, hour: 12))
        #expect(r.values.end == day(1, hour: 13))
        #expect(r.notice == nil)
    }

    @Test("Custom lunch preference (12:30, 45 min) is used")
    func customLunchPreference() throws {
        var prefs = MealPreferences.defaults
        prefs.lunch = MealSetting(minutesAfterMidnight: 12 * 60 + 30, durationMinutes: 45)
        let r = try #require(suggest(body: "Lunch tomorrow?", meals: prefs))
        #expect(r.values.start == day(1, hour: 12, minute: 30))
        #expect(r.values.end == day(1, hour: 13, minute: 15))
    }

    @Test("An explicit time wins; the meal still sets the length")
    func explicitTimeWins() throws {
        let r = try #require(suggest(body: "Dinner tomorrow at 7:00 PM?"))
        #expect(r.values.start == day(1, hour: 19))
        #expect(r.values.end == day(1, hour: 20, minute: 30))
    }

    @Test("Breakfast in the subject uses the breakfast preference")
    func breakfastInSubject() throws {
        let r = try #require(suggest(subject: "Breakfast tomorrow", body: nil))
        #expect(r.values.start == day(1, hour: 8))
        #expect(r.values.end == day(1, hour: 9))
    }

    @Test("No meal and no time → all-day on the anchored day")
    func noMealAllDay() throws {
        let r = try #require(suggest(body: "The movers come tomorrow."))
        #expect(r.values.isAllDay)
        #expect(r.values.start == day(1))
    }

    // MARK: - Stale relative dates

    @Test("Read later but the day is still ahead → corrected date, no notice")
    func laterStillAhead() throws {
        // Sent Wednesday, read Thursday: "the day after tomorrow" = Friday.
        let r = try #require(suggest(body: "Lunch the day after tomorrow?", now: day(1, hour: 10)))
        #expect(r.values.start == day(2, hour: 12))
        #expect(r.notice == nil)
    }

    @Test("Read after the day passed → date kept, notice explains it")
    func stalePassed() throws {
        let r = try #require(suggest(body: "Lunch tomorrow?", now: day(10, hour: 10)))
        #expect(r.found)
        #expect(r.values.start == day(1, hour: 12))
        let notice = try #require(r.notice)
        #expect(notice.contains("“tomorrow”"))
        #expect(notice.contains("has passed"))
    }

    @Test("Absolute past dates are still skipped, not flagged")
    func absolutePastStillSkipped() throws {
        let r = try #require(suggest(body: "We met on March 2, 2020.", now: day(10)))
        #expect(!r.found)
        #expect(r.notice == nil)
    }

    // MARK: - Preferences storage

    @Test("Stored preferences load; out-of-range values fall back to defaults")
    func loadPreferences() throws {
        let suite = "MealPreferencesTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(12 * 60 + 30, forKey: MealPreferences.timeKey(.lunch))
        defaults.set(45, forKey: MealPreferences.durationKey(.lunch))
        defaults.set(99_999, forKey: MealPreferences.timeKey(.dinner))

        let prefs = MealPreferences.load(from: defaults)
        #expect(prefs.lunch == MealSetting(minutesAfterMidnight: 750, durationMinutes: 45))
        #expect(prefs.dinner == MealPreferences.defaults.dinner)
        #expect(prefs.breakfast == MealPreferences.defaults.breakfast)
    }
}
