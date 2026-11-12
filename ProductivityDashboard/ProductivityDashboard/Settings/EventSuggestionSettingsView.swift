// Settings/EventSuggestionSettingsView.swift
//
// Stage 8, Step D2. Settings pane for "Make Event from Email…": the time and
// length used when an email mentions breakfast, lunch or dinner without an
// explicit time. Stored in UserDefaults (plain preferences, no email data).

import SwiftUI

struct EventSuggestionSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Event Suggestions").font(.title3).bold()
            Text("When an email mentions a meal without a time — \u{201C}lunch tomorrow\u{201D} — the suggested event uses these times and lengths. An explicit time in the email always wins. You review every suggestion before anything is added.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                ForEach(Meal.allCases) { meal in
                    MealSettingRow(meal: meal)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Restore Defaults") {
                    for meal in Meal.allCases {
                        UserDefaults.standard.removeObject(forKey: MealPreferences.timeKey(meal))
                        UserDefaults.standard.removeObject(forKey: MealPreferences.durationKey(meal))
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 320)
    }
}

private struct MealSettingRow: View {
    let meal: Meal
    @AppStorage private var minutes: Int
    @AppStorage private var duration: Int

    init(meal: Meal) {
        self.meal = meal
        let d = MealPreferences.defaults[meal]
        _minutes = AppStorage(wrappedValue: d.minutesAfterMidnight, MealPreferences.timeKey(meal))
        _duration = AppStorage(wrappedValue: d.durationMinutes, MealPreferences.durationKey(meal))
    }

    private var time: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(byAdding: .minute, value: minutes,
                                      to: Calendar.current.startOfDay(for: .now)) ?? .now
            },
            set: { newValue in
                let c = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            })
    }

    var body: some View {
        HStack {
            Text(meal.displayName).frame(width: 90, alignment: .leading)
            DatePicker("Time", selection: time, displayedComponents: .hourAndMinute)
                .labelsHidden()
            Spacer()
            Picker("Length", selection: $duration) {
                ForEach(MealPreferences.durationChoices, id: \.self) { m in
                    Text(Self.label(m)).tag(m)
                }
            }
            .frame(width: 160)
        }
    }

    static func label(_ minutes: Int) -> String {
        switch minutes {
        case ..<60: return "\(minutes) min"
        case 60: return "1 hour"
        default:
            let h = Double(minutes) / 60
            return h == h.rounded() ? "\(Int(h)) hours" : String(format: "%.1f hours", h)
        }
    }
}
