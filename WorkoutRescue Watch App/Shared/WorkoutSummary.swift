import Foundation

/// A lightweight, read-only view of a HealthKit workout used by the list (no samples, no route).
nonisolated struct WorkoutSummary: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let activityTypeRawValue: UInt
    let startDate: Date
    let endDate: Date
    let duration: TimeInterval
    let totalDistanceMeters: Double?
    let totalActiveEnergyKilocalories: Double?
    let sourceName: String?
    let isDemoData: Bool

    init(id: UUID, activityTypeRawValue: UInt, startDate: Date, endDate: Date, duration: TimeInterval, totalDistanceMeters: Double? = nil, totalActiveEnergyKilocalories: Double? = nil, sourceName: String? = nil, isDemoData: Bool = false) {
        self.id = id
        self.activityTypeRawValue = activityTypeRawValue
        self.startDate = startDate
        self.endDate = endDate
        self.duration = duration
        self.totalDistanceMeters = totalDistanceMeters
        self.totalActiveEnergyKilocalories = totalActiveEnergyKilocalories
        self.sourceName = sourceName
        self.isDemoData = isDemoData
    }

    var activityDisplayName: String { ActivityTypeNames.name(for: activityTypeRawValue) }

    var durationText: String { Duration.seconds(max(0, duration)).formatted(.time(pattern: .hourMinuteSecond)) }

    var distanceText: String? {
        guard let totalDistanceMeters else { return nil }
        return Measurement(value: totalDistanceMeters / 1000, unit: UnitLength.kilometers).formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(2))))
    }
}
