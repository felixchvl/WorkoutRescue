import Foundation

/// Names for `HKWorkoutActivityType` raw values (stable, documented HealthKit enum values).
/// Kept HealthKit-free so the table can be unit tested on macOS; `ActivityTypeNamesTests`
/// checks it against the real HealthKit enum when HealthKit is importable.
nonisolated enum ActivityTypeNames {
    static let byRawValue: [UInt: String] = [
        1: "American Football", 2: "Archery", 3: "Australian Football", 4: "Badminton", 5: "Baseball",
        6: "Basketball", 7: "Bowling", 8: "Boxing", 9: "Climbing", 10: "Cricket", 11: "Cross Training",
        12: "Curling", 13: "Cycling", 14: "Dance", 15: "Dance Inspired Training", 16: "Elliptical",
        17: "Equestrian Sports", 18: "Fencing", 19: "Fishing", 20: "Functional Strength Training", 21: "Golf",
        22: "Gymnastics", 23: "Handball", 24: "Hiking", 25: "Hockey", 26: "Hunting", 27: "Lacrosse",
        28: "Martial Arts", 29: "Mind and Body", 30: "Mixed Metabolic Cardio Training", 31: "Paddle Sports",
        32: "Play", 33: "Preparation and Recovery", 34: "Racquetball", 35: "Rowing", 36: "Rugby", 37: "Running",
        38: "Sailing", 39: "Skating Sports", 40: "Snow Sports", 41: "Soccer", 42: "Softball", 43: "Squash",
        44: "Stair Climbing", 45: "Surfing Sports", 46: "Swimming", 47: "Table Tennis", 48: "Tennis",
        49: "Track and Field", 50: "Traditional Strength Training", 51: "Volleyball", 52: "Walking",
        53: "Water Fitness", 54: "Water Polo", 55: "Water Sports", 56: "Wrestling", 57: "Yoga", 58: "Barre",
        59: "Core Training", 60: "Cross Country Skiing", 61: "Downhill Skiing", 62: "Flexibility",
        63: "High Intensity Interval Training", 64: "Jump Rope", 65: "Kickboxing", 66: "Pilates",
        67: "Snowboarding", 68: "Stairs", 69: "Step Training", 70: "Wheelchair Walk Pace",
        71: "Wheelchair Run Pace", 72: "Tai Chi", 73: "Mixed Cardio", 74: "Hand Cycling", 75: "Disc Sports",
        76: "Fitness Gaming", 77: "Cardio Dance", 78: "Social Dance", 79: "Pickleball", 80: "Cooldown",
        82: "Swim Bike Run", 83: "Transition", 84: "Underwater Diving", 3000: "Other",
    ]

    static func name(for rawValue: UInt) -> String { byRawValue[rawValue] ?? "Workout (type \(rawValue))" }

    static let cycling: UInt = 13
}
