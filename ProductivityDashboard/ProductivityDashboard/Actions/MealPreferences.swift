// Actions/MealPreferences.swift
//
// Stage 8, Step D2 (Matt, 2026-09-17). Default times and lengths for meal
// events suggested from email ("lunch tomorrow" → tomorrow at the lunch
// time, for the lunch length). A plain preference — not a secret and not
// inbox-derived — stored in UserDefaults like the cloud model choice.

import Foundation

nonisolated enum Meal: String, CaseIterable, Identifiable, Sendable {
    case breakfast, lunch, dinner
    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }

    /// Words that name the meal. Brunch → breakfast; supper → dinner.
    var words: [String] {
        switch self {
        case .breakfast: return ["breakfast", "brunch"]
        case .lunch:     return ["lunch", "luncheon"]
        case .dinner:    return ["dinner", "supper"]
        }
    }
}

nonisolated struct MealSetting: Equatable, Sendable {
    var minutesAfterMidnight: Int
    var durationMinutes: Int
}

nonisolated struct MealPreferences: Equatable, Sendable {
    var breakfast: MealSetting
    var lunch: MealSetting
    var dinner: MealSetting

    static let defaults = MealPreferences(
        breakfast: MealSetting(minutesAfterMidnight: 8 * 60, durationMinutes: 60),
        lunch: MealSetting(minutesAfterMidnight: 12 * 60, durationMinutes: 60),
        dinner: MealSetting(minutesAfterMidnight: 18 * 60 + 30, durationMinutes: 90))

    static let durationChoices = [15, 30, 45, 60, 90, 120, 150, 180]

    subscript(meal: Meal) -> MealSetting {
        get {
            switch meal {
            case .breakfast: return breakfast
            case .lunch:     return lunch
            case .dinner:    return dinner
            }
        }
        set {
            switch meal {
            case .breakfast: breakfast = newValue
            case .lunch:     lunch = newValue
            case .dinner:    dinner = newValue
            }
        }
    }

    // MARK: Storage (UserDefaults keys; AppStorage in the Settings pane)

    static func timeKey(_ meal: Meal) -> String { "eventSuggestions.\(meal.rawValue).minutesAfterMidnight" }
    static func durationKey(_ meal: Meal) -> String { "eventSuggestions.\(meal.rawValue).durationMinutes" }

    /// Stored values, falling back to defaults; out-of-range values are
    /// ignored rather than trusted.
    static func load(from defaults: UserDefaults = .standard) -> MealPreferences {
        var prefs = MealPreferences.defaults
        for meal in Meal.allCases {
            if let minutes = defaults.object(forKey: timeKey(meal)) as? Int, (0..<1_440).contains(minutes) {
                prefs[meal].minutesAfterMidnight = minutes
            }
            if let duration = defaults.object(forKey: durationKey(meal)) as? Int, (5...720).contains(duration) {
                prefs[meal].durationMinutes = duration
            }
        }
        return prefs
    }
}
