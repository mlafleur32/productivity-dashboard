// Calendar/CalendarViewModel.swift
//
// SwiftUI-facing state for the Upcoming Calendar section. @Observable,
// owned by ContentView as @State. Holds the auth status, the event list,
// and any load error. Calls into CalendarSource — never into EventKit
// directly — so a fake source can drive it in tests.

import Foundation
import Observation

@Observable
final class CalendarViewModel {
    private let source: CalendarSource
    private let daysAhead: Int
    private let limit: Int

    private(set) var events: [CalendarEvent] = []
    private(set) var authorization: CalendarAuthorization = .notDetermined
    private(set) var loadError: String?

    init(source: CalendarSource = EventKitCalendarSource(), daysAhead: Int = 7, limit: Int = 5) {
        self.source = source
        self.daysAhead = daysAhead
        self.limit = limit
        self.authorization = source.currentAuthorization()
    }

    func load() async {
        loadError = nil

        if authorization == .notDetermined {
            do {
                authorization = try await source.requestAccess()
            } catch {
                loadError = "Couldn't request calendar access: \(error.localizedDescription)"
                return
            }
        }

        guard authorization == .authorized else { return }

        do {
            events = try await source.fetchUpcomingEvents(daysAhead: daysAhead, limit: limit)
        } catch {
            loadError = "Couldn't load calendar events: \(error.localizedDescription)"
        }
    }
}
