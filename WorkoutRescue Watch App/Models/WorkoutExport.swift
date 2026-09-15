import Foundation

/// Versioned, loss-preserving-on-export archival representation. All dates encode as ISO 8601.
struct WorkoutExport: Codable, Hashable, Sendable {
    static let schemaVersion = 1
    let schemaVersion: Int
    let workout: WorkoutExportIdentity
    let summary: WorkoutExportSummary
    let metadata: [String: String]
    let quantitySamples: [QuantitySampleExport]
    let routes: [RouteExport]

    init(workout: WorkoutExportIdentity, summary: WorkoutExportSummary, metadata: [String: String], quantitySamples: [QuantitySampleExport], routes: [RouteExport]) {
        self.schemaVersion = Self.schemaVersion
        self.workout = workout
        self.summary = summary
        self.metadata = metadata
        self.quantitySamples = quantitySamples
        self.routes = routes
    }
}

struct WorkoutExportIdentity: Codable, Hashable, Sendable {
    let uuid: UUID
    let activityTypeRawValue: UInt
    let sourceName: String?
    let sourceBundleIdentifier: String?
}

struct WorkoutExportSummary: Codable, Hashable, Sendable {
    let startDate: Date
    let endDate: Date
    let durationSeconds: TimeInterval
    let totalDistanceMeters: Double?
    let activeEnergyKilocalories: Double?
}

struct QuantitySampleExport: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let typeIdentifier: String
    let startDate: Date
    let endDate: Date
    let value: Double
    let unit: String
}

struct RouteExport: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let points: [RoutePointExport]
}

struct RoutePointExport: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    let altitude: Double?
    let horizontalAccuracy: Double?
    let verticalAccuracy: Double?
    let speed: Double?
    let course: Double?
}
