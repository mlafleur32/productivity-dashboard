// Calendar/NewEventSheet.swift
//
// Stage 8, Step D. The New Event form — the same sheet whether the user
// clicked New Event (blank) or "Make Event from Email…" (suggested values).
// It only EDITS NewEventFormValues. "Review…" runs NewEventValidator; a valid
// draft is handed back to ContentView, which shows the confirmation dialog.
// Nothing is written from here.

import SwiftUI
import SwiftData

/// One request to open the form.
struct EventFormRequest: Identifiable {
    let id = UUID()
    let values: NewEventFormValues
    let dateFound: Bool
    var notice: String? = nil
}

/// Pure copy for the form banner and the confirmation dialog (unit-tested).
enum EventFormCopy {
    static func suggestionBanner(sender: String) -> String {
        "Suggested from an email from \(sender) — check every field."
    }

    static func when(_ draft: NewEventDraft) -> String {
        if draft.isAllDay {
            // EventKit's all-day end is the start of the following day.
            let lastDay = draft.end.addingTimeInterval(-1)
            let first = draft.start.formatted(date: .abbreviated, time: .omitted)
            let last = lastDay.formatted(date: .abbreviated, time: .omitted)
            return first == last ? "\(first) (all day)" : "\(first) – \(last) (all day)"
        }
        let start = draft.start.formatted(date: .abbreviated, time: .shortened)
        let sameDay = Calendar.current.isDate(draft.start, inSameDayAs: draft.end)
        let end = sameDay ? draft.end.formatted(date: .omitted, time: .shortened)
                          : draft.end.formatted(date: .abbreviated, time: .shortened)
        return "\(start) – \(end)"
    }

    static func dialogMessage(_ draft: NewEventDraft) -> String {
        var text = "“\(draft.title)”\n\(when(draft))\nCalendar: \(draft.calendar.title)"
        if draft.notes != nil {
            text += "\nNotes: a reference to the email"
        }
        if case .suggestedFromEmail(let sender) = draft.source {
            text += "\n\n" + suggestionBanner(sender: sender)
        }
        return text
    }
}

struct NewEventSheet: View {
    @State private var values: NewEventFormValues
    @State private var problems: [NewEventProblem] = []
    private let dateFound: Bool
    private let notice: String?
    private let writableCalendars: [WritableCalendar]
    private let onReview: (NewEventDraft) -> Void
    private let onCancel: () -> Void

    init(request: EventFormRequest, writableCalendars: [WritableCalendar],
         onReview: @escaping (NewEventDraft) -> Void, onCancel: @escaping () -> Void) {
        _values = State(initialValue: request.values)
        self.dateFound = request.dateFound
        self.notice = request.notice
        self.writableCalendars = writableCalendars
        self.onReview = onReview
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(values.source.isSuggested ? "New Event from Email" : "New Event")
                .font(.title2).bold()

            if case .suggestedFromEmail(let sender) = values.source {
                Label(EventFormCopy.suggestionBanner(sender: sender), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if let notice {
                    Label(notice, systemImage: "clock.badge.exclamationmark")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !dateFound {
                    Text("No date was found in the email. Choose one below.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            Form {
                TextField("Title", text: $values.title)
                Toggle("All-day", isOn: $values.isAllDay)
                dateRow(label: "Starts", date: $values.start)
                dateRow(label: "Ends", date: $values.end)
                Picker("Calendar", selection: $values.calendarID) {
                    Text("Choose…").tag(String?.none)
                    ForEach(writableCalendars) { cal in
                        Text(cal.title).tag(String?.some(cal.id))
                    }
                }
                if let reference = values.emailReference {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Add a reference to this email in the event notes",
                               isOn: $values.includeEmailReferenceInNotes)
                        if values.includeEmailReferenceInNotes {
                            Text(reference.notesText)
                                .font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Notes sync wherever this calendar syncs. The email's text is never copied.")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            if !problems.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(problems, id: \.self) { problem in
                        Text(problem.userMessage).font(.callout).foregroundStyle(.red)
                    }
                }
            }

            Text("Nothing is added to your calendar until you confirm on the next step.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Review…", action: review)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 480)
        .onChange(of: values.start) { _, newStart in
            // Keep end sensible when start moves: never before start.
            guard let newStart else { return }
            if values.end == nil || values.end! < newStart {
                values.end = values.isAllDay ? newStart : newStart.addingTimeInterval(3_600)
            }
        }
    }

    @ViewBuilder
    private func dateRow(label: String, date: Binding<Date?>) -> some View {
        if let current = date.wrappedValue {
            DatePicker(label,
                       selection: Binding(get: { current }, set: { date.wrappedValue = $0 }),
                       displayedComponents: values.isAllDay ? [.date] : [.date, .hourAndMinute])
        } else {
            LabeledContent(label) {
                Button("Choose…") { date.wrappedValue = Self.nextWholeHour() }
            }
        }
    }

    private static func nextWholeHour(from now: Date = .now) -> Date {
        let cal = Calendar.current
        let hour = cal.dateInterval(of: .hour, for: now)?.start ?? now
        return hour.addingTimeInterval(3_600)
    }

    private func review() {
        switch NewEventValidator.validate(values, writableCalendars: writableCalendars) {
        case .valid(let draft):
            problems = []
            onReview(draft)
        case .invalid(let found):
            problems = found
        }
    }
}

/// Stage 8: the undo surface for created events. Titles/times are read back
/// live from the calendar by identifier (the log stores neither). Hidden
/// when nothing is open.
struct RecentlyCreatedEventsSection: View {
    @Query(filter: #Predicate<CalendarActionLogEntry> { $0.undoneAt == nil },
           sort: \CalendarActionLogEntry.timestamp, order: .reverse)
    private var openEntries: [CalendarActionLogEntry]

    let summary: (String) -> CreatedEventSummary?
    let isWorking: Bool
    let onUndo: (String) -> Void

    private static let displayLimit = 5

    var body: some View {
        if !openEntries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recently Created Events").font(.title2).bold()
                ForEach(openEntries.prefix(Self.displayLimit), id: \.eventIdentifier) { entry in
                    HStack {
                        if let s = summary(entry.eventIdentifier) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.title).font(.callout).lineLimit(1)
                                Text(s.isAllDay ? s.start.formatted(date: .abbreviated, time: .omitted) + " (all day)"
                                                : s.start.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Text("(no longer in your calendar)").font(.callout).foregroundStyle(.secondary)
                        }
                        if entry.sourceKind == "fromEmail" {
                            Image(systemName: "envelope").font(.caption).foregroundStyle(.tertiary)
                                .help("Created from an email suggestion")
                        }
                        Spacer()
                        if isWorking {
                            ProgressView().controlSize(.mini)
                        } else {
                            Button("Undo") { onUndo(entry.eventIdentifier) }
                                .buttonStyle(.borderless)
                                .font(.callout)
                        }
                    }
                }
                Divider()
            }
        }
    }
}
