import Foundation

// Portable archive model. This folder is compiled both into the watch app and into the
// `WorkoutRescueCore` Swift package used by the macOS test suite, so it must not import
// HealthKit, WatchKit or SwiftUI. HealthKit objects are converted in `HealthKitService`.

/// Versioned archival representation of one workout. JSON is the source of truth.
///
/// Conversion rules (see `docs/JSON-SCHEMA.md`):
/// - every `Date` is an ISO 8601 UTC string with microsecond precision (`ArchiveDateCoding`);
/// - every quantity carries its HealthKit unit string next to the value;
/// - raw CoreLocation values are kept as-is, including the negative "invalid" sentinels;
/// - non-finite doubles are encoded as the strings "NaN", "Infinity", "-Infinity";
/// - metadata values are typed (`MetadataValue`) instead of being stringified.
nonisolated struct WorkoutArchive: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 2
    static let formatIdentifier = "workoutrescue.workout"

    var format: String = Self.formatIdentifier
    var schemaVersion: Int = Self.currentSchemaVersion
    var exportedAt: Date
    var exporter: ExporterInfo
    /// True only for the built-in fictional demo workouts. Never true for HealthKit data.
    var isDemoData: Bool
    var workout: WorkoutRecord
    var quantityTypes: [QuantityTypeExport]
    var routes: [RouteExport]
    /// Non-fatal problems met while reading optional data (one failed type never aborts the archive).
    var warnings: [String]

    var totalRoutePointCount: Int { routes.reduce(0) { $0 + $1.points.count } }
    func sampleCount(for typeIdentifier: String) -> Int {
        quantityTypes.first { $0.typeIdentifier == typeIdentifier }?.samples.count ?? 0
    }
}

nonisolated struct ExporterInfo: Codable, Hashable, Sendable {
    var app: String = "WorkoutRescue"
    var appVersion: String?
    var appBuild: String?
    var platform: String
    var operatingSystemVersion: String?
}

nonisolated struct WorkoutRecord: Codable, Hashable, Sendable {
    var uuid: UUID
    var activityType: ActivityTypeExport
    var startDate: Date
    var endDate: Date
    var durationSeconds: Double
    var totalDistance: MeasuredValue?
    var totalEnergyBurned: MeasuredValue?
    var totalSwimmingStrokeCount: MeasuredValue?
    var totalFlightsClimbed: MeasuredValue?
    var source: SourceExport
    var device: DeviceExport?
    var metadata: [String: MetadataValue]
    var statistics: [StatisticsExport]
    var activities: [WorkoutActivityExport]
    var events: [WorkoutEventExport]
}

nonisolated struct ActivityTypeExport: Codable, Hashable, Sendable {
    var rawValue: UInt
    var name: String
    init(rawValue: UInt) {
        self.rawValue = rawValue
        self.name = ActivityTypeNames.name(for: rawValue)
    }
}

nonisolated struct MeasuredValue: Codable, Hashable, Sendable {
    var value: Double
    var unit: String
}

nonisolated struct SourceExport: Codable, Hashable, Sendable {
    var name: String?
    var bundleIdentifier: String?
    var version: String?
    var productType: String?
    var operatingSystemVersion: String?
}

nonisolated struct DeviceExport: Codable, Hashable, Sendable {
    var name: String?
    var manufacturer: String?
    var model: String?
    var hardwareVersion: String?
    var firmwareVersion: String?
    var softwareVersion: String?
    var localIdentifier: String?
    var udiDeviceIdentifier: String?
}

/// HKStatistics summary (global aggregate). Not to be confused with time series samples.
nonisolated struct StatisticsExport: Codable, Hashable, Sendable {
    var typeIdentifier: String
    var unit: String
    var startDate: Date
    var endDate: Date
    var sum: Double?
    var average: Double?
    var minimum: Double?
    var maximum: Double?
    var mostRecent: Double?
}

nonisolated struct WorkoutActivityExport: Codable, Hashable, Sendable {
    var uuid: UUID
    var activityType: ActivityTypeExport
    var locationType: Int?
    var swimmingLocationType: Int?
    var lapLength: MeasuredValue?
    var startDate: Date
    var endDate: Date?
    var durationSeconds: Double
    var metadata: [String: MetadataValue]
    var statistics: [StatisticsExport]
    var events: [WorkoutEventExport]
}

nonisolated struct WorkoutEventExport: Codable, Hashable, Sendable {
    /// `HKWorkoutEventType` raw value (1 pause, 2 resume, 3 lap, 4 marker, 5 motionPaused, 6 motionResumed, 7 segment, 8 pauseOrResumeRequest).
    var typeRawValue: Int
    var typeName: String
    var startDate: Date
    var endDate: Date
    var metadata: [String: MetadataValue]
}

/// All samples of one HealthKit quantity type that relate to the workout.
nonisolated struct QuantityTypeExport: Codable, Hashable, Sendable {
    enum Strategy: String, Codable, Sendable {
        /// `HKQuery.predicateForObjects(from: workout)` — samples explicitly associated with the workout.
        case associatedWithWorkout
        /// No associated sample found: samples whose interval lies inside the workout interval, any source.
        case workoutTimeRange
        /// Built-in fictional data.
        case demo
    }
    var typeIdentifier: String
    var unit: String
    var strategy: Strategy
    var samples: [QuantitySampleExport]
    /// Set when the query for this type failed; the rest of the archive is still exported.
    var error: String?
}

nonisolated struct QuantitySampleExport: Codable, Hashable, Sendable {
    var uuid: UUID
    var startDate: Date
    var endDate: Date
    /// `quantity` converted to the type unit. For a series sample this is the aggregate.
    var value: Double
    /// `HKQuantitySample.count` (> 1 means the sample is a series; see `series`).
    var count: Int
    var sourceName: String?
    var sourceBundleIdentifier: String?
    var deviceName: String?
    var metadata: [String: MetadataValue]?
    /// Individual quantities of a series sample (only when `count > 1`).
    var series: [SeriesValueExport]?
}

nonisolated struct SeriesValueExport: Codable, Hashable, Sendable {
    var startDate: Date
    var endDate: Date
    var value: Double
}

nonisolated struct RouteExport: Codable, Hashable, Sendable {
    var uuid: UUID
    var startDate: Date
    var endDate: Date
    /// `HKWorkoutRoute.count` as reported by HealthKit, used to verify that no point was lost.
    var expectedPointCount: Int?
    var metadata: [String: MetadataValue]
    var points: [RoutePointExport]
    /// Set when reading this route failed or ended early; points read so far are kept.
    var error: String?

    var isComplete: Bool { error == nil && (expectedPointCount.map { $0 == points.count } ?? true) }
}

/// Raw CLLocation values. Negative accuracies/speed/course are CoreLocation "invalid" markers, kept verbatim.
nonisolated struct RoutePointExport: Codable, Hashable, Sendable {
    var timestamp: Date
    var latitude: Double
    var longitude: Double
    var altitude: Double
    var ellipsoidalAltitude: Double?
    var horizontalAccuracy: Double
    var verticalAccuracy: Double
    var speed: Double
    var speedAccuracy: Double?
    var course: Double
    var courseAccuracy: Double?
    var floor: Int?

    /// CoreLocation: a negative horizontal accuracy means the coordinate is invalid.
    var hasValidCoordinate: Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
            && horizontalAccuracy >= 0
    }
    /// CoreLocation: a negative vertical accuracy means the altitude is invalid.
    var hasValidAltitude: Bool { altitude.isFinite && verticalAccuracy >= 0 }
}

/// Explicit conversion of HealthKit metadata values (`[String: Any]`).
nonisolated enum MetadataValue: Codable, Hashable, Sendable {
    case string(String)
    case integer(Int64)
    case double(Double)
    case bool(Bool)
    case date(Date)
    case quantity(value: Double, unit: String, description: String)
    /// A value whose type has no documented JSON mapping; we keep its type name and description.
    case unsupported(typeName: String, description: String)

    private enum CodingKeys: String, CodingKey { case type, value, unit, description, typeName }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let v): try c.encode("string", forKey: .type); try c.encode(v, forKey: .value)
        case .integer(let v): try c.encode("integer", forKey: .type); try c.encode(v, forKey: .value)
        case .double(let v): try c.encode("double", forKey: .type); try c.encode(v, forKey: .value)
        case .bool(let v): try c.encode("bool", forKey: .type); try c.encode(v, forKey: .value)
        case .date(let v): try c.encode("date", forKey: .type); try c.encode(v, forKey: .value)
        case .quantity(let v, let unit, let d):
            try c.encode("quantity", forKey: .type); try c.encode(v, forKey: .value)
            try c.encode(unit, forKey: .unit); try c.encode(d, forKey: .description)
        case .unsupported(let t, let d):
            try c.encode("unsupported", forKey: .type); try c.encode(t, forKey: .typeName); try c.encode(d, forKey: .description)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "string": self = .string(try c.decode(String.self, forKey: .value))
        case "integer": self = .integer(try c.decode(Int64.self, forKey: .value))
        case "double": self = .double(try c.decode(Double.self, forKey: .value))
        case "bool": self = .bool(try c.decode(Bool.self, forKey: .value))
        case "date": self = .date(try c.decode(Date.self, forKey: .value))
        case "quantity":
            self = .quantity(value: try c.decode(Double.self, forKey: .value), unit: try c.decode(String.self, forKey: .unit),
                             description: try c.decode(String.self, forKey: .description))
        default:
            self = .unsupported(typeName: (try? c.decode(String.self, forKey: .typeName)) ?? "unknown",
                                description: (try? c.decode(String.self, forKey: .description)) ?? "")
        }
    }

    /// Converts Foundation values. HealthKit quantities are converted by the HealthKit layer before reaching this.
    static func from(_ value: Any) -> MetadataValue {
        switch value {
        case let s as String: return .string(s)
        case let d as Date: return .date(d)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            if CFNumberIsFloatType(n) { return .double(n.doubleValue) }
            return .integer(n.int64Value)
        default: return .unsupported(typeName: String(describing: type(of: value)), description: String(describing: value))
        }
    }
}
