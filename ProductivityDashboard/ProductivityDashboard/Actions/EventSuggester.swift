// Actions/EventSuggester.swift
//
// Stage 8, Step B — "Make Event from Email…" suggestions (settled with Matt
// 2026-09-16; ARCHITECTURE.md Stage 8 "Suggested events", THREAT_PATTERNS.md
// Prompt Injection revision).
//
// Turns one email into INITIAL VALUES for the New Event form. Nothing here
// creates, validates or confirms anything: the result is a
// NewEventFormValues the user reviews field by field, and only
// NewEventValidator + the confirmation dialog can turn it into an event.
//
// Bounds, all enforced here:
//   - On-device only: Apple's NSDataDetector. No network, no cloud path.
//   - Only title, start, end, all-day are suggested. The calendar is the
//     caller-supplied default (never derived from the email); links, notes,
//     location and invitees have no field to land in.
//   - Refused for local scam, cloud phishing/suspicious and trusted
//     dmarc=fail mail — the UI doesn't offer the choice at all.
//   - No usable date → start/end left empty (the form requires them).

import Foundation

nonisolated enum EventSuggestionRefusal: Equatable, Sendable {
    case scam
    case cloudFlagged
    case dmarcFailed
}

/// What a row shows when an on-device scan found a date in an email
/// (Step D5, Matt 2026-09-27). Derived from a body that is fetched and
/// DISCARDED in the same pass: no body text is kept, nothing is persisted,
/// nothing is sent anywhere, and nothing is created — it only offers the
/// same reviewed form the context menu opens.
nonisolated struct EventHint: Equatable, Sendable {
    let start: Date
    let isAllDay: Bool

    var label: String {
        isAllDay
            ? start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            : start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }
}

/// The start times of events this app created and hasn't undone, so a row
/// whose hint resolves to one of them can say "Event created" too (Matt
/// 2026-09-28: one thread, one event — the earlier mails in it shouldn't
/// still invite a second copy). Times are compared to the minute, and
/// all-day events by day, because a suggestion and the event made from it
/// go through the same rounding.
nonisolated struct CreatedEventTimes: Equatable, Sendable {
    private var timed: Set<Date> = []
    private var allDay: Set<Date> = []

    init() {}

    static func minute(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate:
                (date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
    }

    static func day(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date)
    }

    mutating func insert(start: Date, isAllDay: Bool, calendar: Calendar = .current) {
        if isAllDay {
            allDay.insert(Self.day(start, calendar: calendar))
        } else {
            timed.insert(Self.minute(start))
        }
    }

    func contains(_ hint: EventHint, calendar: Calendar = .current) -> Bool {
        hint.isAllDay
            ? allDay.contains(Self.day(hint.start, calendar: calendar))
            : timed.contains(Self.minute(hint.start))
    }

    var isEmpty: Bool { timed.isEmpty && allDay.isEmpty }
}

nonisolated enum EventSuggestionResult: Equatable, Sendable {
    case refused(EventSuggestionRefusal)
    /// Form values to review. `dateFound` is false when no usable date was
    /// detected (start/end are nil). `notice` explains a relative date that
    /// had already passed when the suggestion was made ("tomorrow" in an
    /// email from last week).
    case suggestion(NewEventFormValues, dateFound: Bool, notice: String?)
}

/// How a detected date relates to when the email was sent (Step D2).
nonisolated enum RelativeDay: Equatable, Sendable {
    case absolute                 // "October 15", "10/15" — not re-anchored
    case offset(days: Int, word: String)   // today/tonight = 0, tomorrow = 1, …
    case weekday(Int, word: String)        // Calendar weekday 1 (Sun)…7 (Sat)
}

/// One date/time found in text.
nonisolated struct DetectedEventTime: Equatable, Sendable {
    let start: Date
    let duration: TimeInterval   // 0 when the text gave no range
    let hasTime: Bool            // false = a date only → all-day
    var relative: RelativeDay = .absolute
}

extension RelativeDay {
    var word: String? {
        switch self {
        case .absolute: return nil
        case .offset(_, let word), .weekday(_, let word): return word
        }
    }
}

enum EventSuggester {

    static let defaultDuration: TimeInterval = 3_600
    static let maxBodyCharacters = 20_000

    // MARK: Eligibility

    static func refusal(localCategory: MailCategory?,
                        cloudVerdict: CloudVerdict?,
                        authentication: AuthenticationResults?) -> EventSuggestionRefusal? {
        if localCategory == .scam { return .scam }
        if let scam = cloudVerdict?.scam, scam != .clean { return .cloudFlagged }
        if authentication?.dmarc == .fail { return .dmarcFailed }
        return nil
    }

    // MARK: Suggestion

    /// - Parameters:
    ///   - body: the plain-text body from the local IMAP fetch, or nil. It is
    ///     stripped of quoted replies/signatures first, so a date in old
    ///     thread history doesn't win.
    ///   - meals: preferred times/lengths for breakfast, lunch and dinner.
    ///   - now: ABSOLUTE dates before today are skipped ("sent on Sept 1"
    ///     is not the meeting). RELATIVE dates ("tomorrow", "Friday") are
    ///     re-anchored to when the email was sent; if that day has passed,
    ///     it is still suggested, with a notice.
    static func suggest(for message: MailMessage,
                        body: String?,
                        localCategory: MailCategory?,
                        cloudVerdict: CloudVerdict?,
                        defaultCalendarID: String?,
                        meals: MealPreferences = .defaults,
                        now: Date = .now,
                        calendar: Calendar = .current) -> EventSuggestionResult {
        if let reason = refusal(localCategory: localCategory, cloudVerdict: cloudVerdict,
                                authentication: message.authentication) {
            return .refused(reason)
        }

        let source = EventSource.suggestedFromEmail(sender: message.fromName ?? message.fromAddress)
        var values = NewEventFormValues(title: title(fromSubject: message.subject),
                                        calendarID: defaultCalendarID,
                                        source: source)

        let stripped = body.map { String(EmailStripper.strip($0).prefix(maxBodyCharacters)) }
        let texts = [message.subject] + (stripped.map { [$0] } ?? [])
        let meal = texts.lazy.compactMap { detectMeal(in: $0) }.first
        let today = calendar.startOfDay(for: now)
        let sentDay = calendar.startOfDay(for: message.date)

        // Which detection wins (revised by Matt 2026-09-18): in the body, the
        // LAST time mentioned — in a thread, EmailStripper has already cut
        // the quoted history, so the last time in what's left is the newest
        // message's latest word on it ("...or 1pm if that's easier"). The
        // subject is only the fallback, because the body is where people
        // change the time.
        var chosen: (DetectedEventTime, RelativeDay, Date)?   // detection, kind, anchored day
        func pick(in text: String, lastFirst: Bool) -> (DetectedEventTime, RelativeDay, Date)? {
            let found = detect(in: text)
            for f in (lastFirst ? Array(found.reversed()) : found) {
                let kind = f.relative
                let day = anchoredDay(for: f, kind: kind, sentDay: sentDay, calendar: calendar)
                switch kind {
                case .absolute:
                    if day >= today { return (f, kind, day) }
                case .offset, .weekday:
                    return (f, kind, day)
                }
            }
            return nil
        }
        if let stripped { chosen = pick(in: stripped, lastFirst: true) }
        if chosen == nil { chosen = pick(in: message.subject, lastFirst: false) }

        guard let chosen else {
            return .suggestion(values, dateFound: false, notice: nil)
        }
        let (found, kind, day) = chosen

        if found.hasTime {
            let hm = calendar.dateComponents([.hour, .minute], from: found.start)
            let start = calendar.date(bySettingHour: hm.hour ?? 0, minute: hm.minute ?? 0, second: 0, of: day) ?? day
            let length = found.duration > 0 ? found.duration
                : meal.map { TimeInterval(meals[$0].durationMinutes * 60) } ?? defaultDuration
            values.isAllDay = false
            values.start = start
            values.end = start.addingTimeInterval(length)
        } else if let meal {
            let setting = meals[meal]
            let start = calendar.date(byAdding: .minute, value: setting.minutesAfterMidnight, to: day) ?? day
            values.isAllDay = false
            values.start = start
            values.end = start.addingTimeInterval(TimeInterval(setting.durationMinutes * 60))
        } else {
            // All-day: same start/end date; the validator snaps to whole days.
            values.isAllDay = true
            values.start = day
            values.end = found.duration > 0 ? day.addingTimeInterval(found.duration) : day
        }

        var notice: String?
        if day < today, let word = kind.word {
            let sent = message.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            let meant = day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            notice = "This email said “\(word)” on \(sent), which meant \(meant) — that date has passed."
        }
        return .suggestion(values, dateFound: true, notice: notice)
    }

    // MARK: Relative dates (Step D2)

    /// The calendar day a detection refers to. Relative words are counted
    /// from the day the email was SENT, not the day it's read; weekday names
    /// mean the first such day after the sent day.
    static func anchoredDay(for found: DetectedEventTime, kind: RelativeDay,
                            sentDay: Date, calendar: Calendar) -> Date {
        switch kind {
        case .absolute:
            return calendar.startOfDay(for: found.start)
        case .offset(let days, _):
            return calendar.date(byAdding: .day, value: days, to: sentDay) ?? sentDay
        case .weekday(let weekday, _):
            let sentWeekday = calendar.component(.weekday, from: sentDay)
            var delta = (weekday - sentWeekday + 7) % 7
            if delta == 0 { delta = 7 }
            return calendar.date(byAdding: .day, value: delta, to: sentDay) ?? sentDay
        }
    }

    private static let weekdayWords: [(pattern: String, weekday: Int, word: String)] = [
        ("sun(day)?", 1, "Sunday"), ("mon(day)?", 2, "Monday"), ("tue(s|sday)?", 3, "Tuesday"),
        ("wed(nesday)?", 4, "Wednesday"), ("thu(r|rs|rsday)?", 5, "Thursday"),
        ("fri(day)?", 6, "Friday"), ("sat(urday)?", 7, "Saturday"),
    ]

    /// Classify the text a detector matched.
    static func relativeDay(in matched: String) -> RelativeDay {
        let text = matched.lowercased()
        func has(_ pattern: String) -> Bool {
            text.range(of: #"\b(?:"# + pattern + #")\b"#, options: .regularExpression) != nil
        }
        if has("day after tomorrow") { return .offset(days: 2, word: "the day after tomorrow") }
        if has("tomorrow|tmrw") { return .offset(days: 1, word: "tomorrow") }
        if has("today|tonight|this (?:morning|afternoon|evening)") {
            return .offset(days: 0, word: has("tonight") ? "tonight" : "today")
        }
        // A weekday name only counts as relative when no explicit calendar
        // date is in the same match ("Friday, October 15" is absolute).
        let hasExplicitDate = has(#"\d{1,2}[/.-]\d{1,2}"#)
            || has("jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec|january|february|march|april|june|july|august|september|october|november|december")
        if !hasExplicitDate {
            for entry in weekdayWords where has(entry.pattern) {
                return .weekday(entry.weekday, word: entry.word)
            }
        }
        return .absolute
    }

    /// The first meal named in the text (earliest position wins).
    static func detectMeal(in text: String) -> Meal? {
        let lower = text.lowercased()
        var best: (Meal, String.Index)?
        for meal in Meal.allCases {
            for word in meal.words {
                if let r = lower.range(of: #"\b"# + word + #"\b"#, options: .regularExpression),
                   best == nil || r.lowerBound < best!.1 {
                    best = (meal, r.lowerBound)
                }
            }
        }
        return best?.0
    }

    // MARK: Title

    /// The subject as a one-line title: reply/forward prefixes removed,
    /// control and line-separator characters turned into spaces, whitespace
    /// collapsed, capped at the validator's limit.
    nonisolated static func title(fromSubject subject: String) -> String {
        let cleanedScalars = subject.unicodeScalars.map { scalar -> Character in
            NewEventValidator.isForbiddenInTitle(scalar) ? " " : Character(scalar)
        }
        var text = String(cleanedScalars)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")

        let prefixes = ["re:", "fw:", "fwd:", "aw:", "sv:"]
        var changed = true
        while changed {
            changed = false
            for p in prefixes where text.lowercased().hasPrefix(p) {
                text = String(text.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        if text == "(no subject)" { text = "" }
        return String(text.prefix(NewEventValidator.maxTitleLength))
    }

    // MARK: Detection

    static func firstUpcoming(in text: String, notBefore earliest: Date) -> DetectedEventTime? {
        detect(in: text).first { $0.start >= earliest }
    }

    /// Every date NSDataDetector finds, in text order.
    static func detect(in text: String) -> [DetectedEventTime] {
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        else { return [] }
        let ns = text as NSString
        return detector.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard let date = match.date else { return nil }
            let matched = ns.substring(with: match.range)
            return DetectedEventTime(start: date, duration: max(0, match.duration),
                                     hasTime: mentionsTimeOfDay(matched),
                                     relative: relativeDay(in: matched))
        }
    }

    private static let timePattern = try! NSRegularExpression(
        pattern: #"\b\d{1,2}(:\d{2})?\s*([ap]\.?\s?m\.?)\b|\b\d{1,2}:\d{2}\b|\bnoon\b|\bmidnight\b|\bo'?clock\b"#,
        options: [.caseInsensitive])

    /// NSDataDetector returns a Date either way; this decides whether the
    /// matched text actually named a time (else it's an all-day date).
    static func mentionsTimeOfDay(_ matched: String) -> Bool {
        timePattern.firstMatch(in: matched, range: NSRange(matched.startIndex..., in: matched)) != nil
    }
}
