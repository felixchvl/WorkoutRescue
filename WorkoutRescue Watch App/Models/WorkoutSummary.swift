import Foundation

/// A read-only view of a HealthKit workout. It deliberately contains no mutation API.
struct WorkoutSummary: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let activityTypeRawValue: UInt
    let startDate: Date
    let endDate: Date
    let duration: TimeInterval
    let totalDistanceMeters: Double?
    let totalActiveEnergyKilocalories: Double?
    let sourceName: String?

    init(id: UUID, activityTypeRawValue: UInt, startDate: Date, endDate: Date, duration: TimeInterval, totalDistanceMeters: Double? = nil, totalActiveEnergyKilocalories: Double? = nil, sourceName: String? = nil) {
        self.id = id
        self.activityTypeRawValue = activityTypeRawValue
        self.startDate = startDate
        self.endDate = endDate
        self.duration = duration
        self.totalDistanceMeters = totalDistanceMeters
        self.totalActiveEnergyKilocalories = totalActiveEnergyKilocalories
        self.sourceName = sourceName
    }

    var activityDisplayName: String {
        switch activityTypeRawValue {
        case 1: return "Running"
        case 2: return "Walking"
        case 3: return "Cycling"
        case 5: return "Swimming"
        case 24: return "Hiking"
        case 50: return "Traditional Strength"
        case 63: return "Functional Strength"
        case 73: return "Mixed Cardio"
        default: return "Workout (type \(activityTypeRawValue))"
        }
    }

    var durationText: String { Duration.seconds(duration).formatted(.time(pattern: .hourMinuteSecond)) }

    var distanceText: String? {
        guard let totalDistanceMeters else { return nil }
        return Measurement(value: totalDistanceMeters, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))
    }
}
