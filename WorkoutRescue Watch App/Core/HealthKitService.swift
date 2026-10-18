import Foundation
import HealthKit
import CoreLocation

/// Read-only HealthKit access.
///
/// SAFETY: this file is the only place that touches `HKHealthStore`. It only uses
/// `requestAuthorization(toShare: [], read:)`, `statusForAuthorizationRequest` and query
/// descriptors. It never calls save, delete, workout session or builder APIs, and the share
/// set is always empty, so the app cannot modify or delete any workout.
final class HealthKitService: WorkoutRepository {
    private let reader: HealthArchiveReader

    init(healthStore: HKHealthStore = HKHealthStore()) { self.reader = HealthArchiveReader(store: healthStore) }

    var isDemo: Bool { false }

    func requestReadAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthKitServiceError.healthDataUnavailable }
        try await reader.store.requestAuthorization(toShare: [], read: HealthArchiveReader.readTypes)
    }

    /// Whether the system permission sheet was already shown. HealthKit never reveals whether
    /// *read* access was granted (privacy): an empty result can mean "denied" or "no data".
    func authorizationPromptState() async -> AuthorizationPromptState {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        do {
            switch try await reader.store.statusForAuthorizationRequest(toShare: [], read: HealthArchiveReader.readTypes) {
            case .shouldRequest: return .notYetShown
            case .unnecessary: return .alreadyShown
            default: return .unknown
            }
        } catch { return .unknown }
    }

    func fetchWorkouts() async throws -> [WorkoutSummary] { try await reader.fetchSummaries() }

    func loadArchive(for id: UUID, progress: @escaping @Sendable (String) -> Void) async throws -> WorkoutArchive {
        try await reader.loadArchive(workoutUUID: id, progress: progress)
    }
}

enum HealthKitServiceError: LocalizedError {
    case healthDataUnavailable
    case workoutNotFound
    var errorDescription: String? {
        switch self {
        case .healthDataUnavailable: return "HealthKit is unavailable on this Apple Watch."
        case .workoutNotFound: return "This workout is no longer readable (not found or access withdrawn)."
        }
    }
}

/// Performs the HealthKit reads off the main actor (`@concurrent`) so long routes do not block the UI.
/// `HKHealthStore` is documented as thread-safe.
nonisolated final class HealthArchiveReader: @unchecked Sendable {
    let store: HKHealthStore
    init(store: HKHealthStore) { self.store = store }

    /// Time-series quantity types read for each workout. Each one is exported when present; the
    /// permission request lists exactly these plus workouts and workout routes.
    static let quantityTypeIdentifiers: [HKQuantityTypeIdentifier] = [
        .heartRate, .activeEnergyBurned, .basalEnergyBurned,
        .distanceCycling, .distanceWalkingRunning, .distanceSwimming,
        .cyclingSpeed, .cyclingPower, .cyclingCadence,
        .runningSpeed, .runningPower, .runningStrideLength, .runningVerticalOscillation, .runningGroundContactTime,
        .stepCount, .flightsClimbed, .swimmingStrokeCount, .physicalEffort,
    ]

    static var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
        for identifier in quantityTypeIdentifiers { types.insert(HKQuantityType(identifier)) }
        return types
    }

    // MARK: Units

    /// Canonical unit per type. Values are always exported with the unit string next to them.
    static func preferredUnit(for identifier: HKQuantityTypeIdentifier) -> HKUnit? {
        switch identifier {
        case .heartRate, .cyclingCadence: return HKUnit.count().unitDivided(by: .minute())
        case .activeEnergyBurned, .basalEnergyBurned: return .kilocalorie()
        case .distanceCycling, .distanceWalkingRunning, .distanceSwimming, .runningStrideLength: return .meter()
        case .cyclingSpeed, .runningSpeed: return HKUnit.meter().unitDivided(by: .second())
        case .cyclingPower, .runningPower: return .watt()
        case .runningVerticalOscillation: return .meterUnit(with: .centi)
        case .runningGroundContactTime: return .secondUnit(with: .milli)
        case .stepCount, .flightsClimbed, .swimmingStrokeCount: return .count()
        case .physicalEffort: return HKUnit(from: "kcal/hr·kg")
        default: return nil
        }
    }

    /// Fallback candidates for quantities of unknown type (metadata, future types).
    static let candidateUnits: [HKUnit] = [
        HKUnit.count().unitDivided(by: .minute()), .meter(), HKUnit.meter().unitDivided(by: .second()), .kilocalorie(), .watt(),
        .degreeCelsius(), .percent(), .count(), .second(), HKUnit(from: "kcal/hr·kg"), .gram(), .pascal(), .decibelAWeightedSoundPressureLevel(),
        .literUnit(with: .milli).unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute())), .hertz(), .radianAngle(),
    ]

    static func unit(for type: HKQuantityType, sample: HKQuantity? = nil) -> HKUnit? {
        if let preferred = preferredUnit(for: HKQuantityTypeIdentifier(rawValue: type.identifier)),
           sample.map({ $0.is(compatibleWith: preferred) }) ?? true { return preferred }
        guard let sample else { return nil }
        return candidateUnits.first { sample.is(compatibleWith: $0) }
    }

    /// Never calls `doubleValue(for:)` with an incompatible unit (that raises an Objective-C exception).
    static func value(_ quantity: HKQuantity?, _ unit: HKUnit?) -> Double? {
        guard let quantity, let unit, quantity.is(compatibleWith: unit) else { return nil }
        return quantity.doubleValue(for: unit)
    }

    static func metadata(_ raw: [String: Any]?) -> [String: MetadataValue] {
        guard let raw else { return [:] }
        var result: [String: MetadataValue] = [:]
        for (key, value) in raw {
            if let quantity = value as? HKQuantity {
                if let unit = candidateUnits.first(where: { quantity.is(compatibleWith: $0) }) {
                    result[key] = .quantity(value: quantity.doubleValue(for: unit), unit: unit.unitString, description: quantity.description)
                } else {
                    result[key] = .unsupported(typeName: "HKQuantity", description: quantity.description)
                }
            } else {
                result[key] = MetadataValue.from(value)
            }
        }
        return result
    }

    // MARK: Workout list

    @concurrent
    func fetchSummaries() async throws -> [WorkoutSummary] {
        let descriptor = HKSampleQueryDescriptor(predicates: [.workout()], sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)])
        let workouts = try await descriptor.result(for: store)
        return workouts.map { workout in
            WorkoutSummary(id: workout.uuid, activityTypeRawValue: workout.workoutActivityType.rawValue, startDate: workout.startDate,
                           endDate: workout.endDate, duration: workout.duration, totalDistanceMeters: Self.totalDistanceMeters(workout),
                           totalActiveEnergyKilocalories: Self.value(workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity(), .kilocalorie()),
                           sourceName: workout.sourceRevision.source.name)
        }
    }

    static func totalDistanceMeters(_ workout: HKWorkout) -> Double? {
        for identifier in [HKQuantityTypeIdentifier.distanceCycling, .distanceWalkingRunning, .distanceSwimming, .distanceDownhillSnowSports, .distanceWheelchair] {
            if let meters = value(workout.statistics(for: HKQuantityType(identifier))?.sumQuantity(), .meter()) { return meters }
        }
        return value(workout.totalDistance, .meter())
    }

    // MARK: Full archive

    @concurrent
    func loadArchive(workoutUUID: UUID, progress: @escaping @Sendable (String) -> Void) async throws -> WorkoutArchive {
        progress("Reading workout…")
        let lookup = HKSampleQueryDescriptor(predicates: [.workout(HKQuery.predicateForObject(with: workoutUUID))], sortDescriptors: [])
        guard let workout = try await lookup.result(for: store).first else { throw HealthKitServiceError.workoutNotFound }

        var warnings: [String] = []
        let record = Self.record(for: workout)

        var routes: [RouteExport] = []
        do {
            routes = try await readRoutes(of: workout, progress: progress)
            if routes.isEmpty { warnings.append("No GPS route is associated with this workout in HealthKit.") }
            for route in routes where !route.isComplete {
                warnings.append("Route \(route.uuid.uuidString): \(route.points.count) of \(route.expectedPointCount.map(String.init) ?? "?") points read\(route.error.map { " (\($0))" } ?? "").")
            }
        } catch {
            warnings.append("Route query failed: \(error.localizedDescription)")
        }

        var quantityTypes: [QuantityTypeExport] = []
        for (index, identifier) in Self.quantityTypeIdentifiers.enumerated() {
            try Task.checkCancellation()
            progress("Reading samples \(index + 1)/\(Self.quantityTypeIdentifiers.count)…")
            let export = await readSamples(HKQuantityType(identifier), of: workout)
            if let error = export.error { warnings.append("\(identifier.rawValue): \(error)") }
            if !export.samples.isEmpty || export.error != nil { quantityTypes.append(export) }
        }

        let info = Bundle.main.infoDictionary
        return WorkoutArchive(
            exportedAt: Date(),
            exporter: ExporterInfo(appVersion: info?["CFBundleShortVersionString"] as? String, appBuild: info?["CFBundleVersion"] as? String,
                                   platform: "watchOS", operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString),
            isDemoData: false, workout: record, quantityTypes: quantityTypes, routes: routes, warnings: warnings)
    }

    static func record(for workout: HKWorkout) -> WorkoutRecord {
        let revision = workout.sourceRevision
        let os = revision.operatingSystemVersion
        let device = workout.device.map {
            DeviceExport(name: $0.name, manufacturer: $0.manufacturer, model: $0.model, hardwareVersion: $0.hardwareVersion,
                         firmwareVersion: $0.firmwareVersion, softwareVersion: $0.softwareVersion, localIdentifier: $0.localIdentifier,
                         udiDeviceIdentifier: $0.udiDeviceIdentifier)
        }
        let statistics = Self.statistics(workout.allStatistics)
        func sum(_ identifier: HKQuantityTypeIdentifier) -> MeasuredValue? {
            statistics.first { $0.typeIdentifier == identifier.rawValue }.flatMap { s in s.sum.map { MeasuredValue(value: $0, unit: s.unit) } }
        }
        return WorkoutRecord(
            uuid: workout.uuid, activityType: ActivityTypeExport(rawValue: workout.workoutActivityType.rawValue),
            startDate: workout.startDate, endDate: workout.endDate, durationSeconds: workout.duration,
            totalDistance: totalDistanceMeters(workout).map { MeasuredValue(value: $0, unit: "m") },
            totalEnergyBurned: sum(.activeEnergyBurned),
            totalSwimmingStrokeCount: sum(.swimmingStrokeCount), totalFlightsClimbed: sum(.flightsClimbed),
            source: SourceExport(name: revision.source.name, bundleIdentifier: revision.source.bundleIdentifier, version: revision.version,
                                 productType: revision.productType, operatingSystemVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"),
            device: device, metadata: metadata(workout.metadata), statistics: statistics,
            activities: workout.workoutActivities.map { activity in
                let configuration = activity.workoutConfiguration
                return WorkoutActivityExport(
                    uuid: activity.uuid, activityType: ActivityTypeExport(rawValue: configuration.activityType.rawValue),
                    locationType: configuration.locationType.rawValue, swimmingLocationType: configuration.swimmingLocationType.rawValue,
                    lapLength: value(configuration.lapLength, .meter()).map { MeasuredValue(value: $0, unit: "m") },
                    startDate: activity.startDate, endDate: activity.endDate, durationSeconds: activity.duration,
                    metadata: metadata(activity.metadata), statistics: Self.statistics(activity.allStatistics),
                    events: activity.workoutEvents.map(event))
            },
            events: (workout.workoutEvents ?? []).map(event))
    }

    static func event(_ event: HKWorkoutEvent) -> WorkoutEventExport {
        let names: [Int: String] = [1: "pause", 2: "resume", 3: "lap", 4: "marker", 5: "motionPaused", 6: "motionResumed", 7: "segment", 8: "pauseOrResumeRequest"]
        return WorkoutEventExport(typeRawValue: event.type.rawValue, typeName: names[event.type.rawValue] ?? "type\(event.type.rawValue)",
                                  startDate: event.dateInterval.start, endDate: event.dateInterval.end, metadata: metadata(event.metadata))
    }

    static func statistics(_ all: [HKQuantityType: HKStatistics]) -> [StatisticsExport] {
        all.compactMap { type, s -> StatisticsExport? in
            let anyQuantity = s.sumQuantity() ?? s.averageQuantity() ?? s.mostRecentQuantity() ?? s.maximumQuantity()
            guard let unit = Self.unit(for: type, sample: anyQuantity) else { return nil }
            return StatisticsExport(typeIdentifier: type.identifier, unit: unit.unitString, startDate: s.startDate, endDate: s.endDate,
                                    sum: value(s.sumQuantity(), unit), average: value(s.averageQuantity(), unit),
                                    minimum: value(s.minimumQuantity(), unit), maximum: value(s.maximumQuantity(), unit),
                                    mostRecent: value(s.mostRecentQuantity(), unit))
        }.sorted { $0.typeIdentifier < $1.typeIdentifier }
    }

    // MARK: Routes

    func readRoutes(of workout: HKWorkout, progress: @escaping @Sendable (String) -> Void) async throws -> [RouteExport] {
        let descriptor = HKSampleQueryDescriptor(predicates: [.workoutRoute(HKQuery.predicateForObjects(from: workout))],
                                                 sortDescriptors: [SortDescriptor(\.startDate)])
        let routes = try await descriptor.result(for: store)
        var exports: [RouteExport] = []
        for (index, route) in routes.enumerated() {
            var points: [RoutePointExport] = []
            points.reserveCapacity(route.count)
            var failure: String?
            do {
                // The async sequence drains every batch of the underlying HKWorkoutRouteQuery and ends
                // only when HealthKit reports `done`. Points are kept in the order HealthKit returns them.
                for try await location in HKWorkoutRouteQueryDescriptor(route).results(for: store) {
                    points.append(Self.point(location))
                    if points.count % 2_000 == 0 { progress("Route \(index + 1)/\(routes.count): \(points.count) points…") }
                }
            } catch {
                failure = error.localizedDescription
            }
            progress("Route \(index + 1)/\(routes.count): \(points.count) points")
            exports.append(RouteExport(uuid: route.uuid, startDate: route.startDate, endDate: route.endDate, expectedPointCount: route.count,
                                       metadata: Self.metadata(route.metadata), points: points, error: failure))
        }
        return exports
    }

    static func point(_ location: CLLocation) -> RoutePointExport {
        RoutePointExport(timestamp: location.timestamp, latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                         altitude: location.altitude, ellipsoidalAltitude: location.ellipsoidalAltitude,
                         horizontalAccuracy: location.horizontalAccuracy, verticalAccuracy: location.verticalAccuracy,
                         speed: location.speed, speedAccuracy: location.speedAccuracy, course: location.course,
                         courseAccuracy: location.courseAccuracy, floor: location.floor?.level)
    }

    // MARK: Samples

    func readSamples(_ type: HKQuantityType, of workout: HKWorkout) async -> QuantityTypeExport {
        let identifier = HKQuantityTypeIdentifier(rawValue: type.identifier)
        var unit = Self.preferredUnit(for: identifier)
        do {
            var predicate = HKQuery.predicateForObjects(from: workout)
            var strategy = QuantityTypeExport.Strategy.associatedWithWorkout
            var samples = try await HKSampleQueryDescriptor(predicates: [.quantitySample(type: type, predicate: predicate)],
                                                            sortDescriptors: [SortDescriptor(\.startDate)]).result(for: store)
            if samples.isEmpty {
                predicate = HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate, options: [.strictStartDate, .strictEndDate])
                strategy = .workoutTimeRange
                samples = try await HKSampleQueryDescriptor(predicates: [.quantitySample(type: type, predicate: predicate)],
                                                            sortDescriptors: [SortDescriptor(\.startDate)]).result(for: store)
            }
            if unit == nil { unit = Self.unit(for: type, sample: samples.first?.quantity) }

            // Series samples (count > 1) hold many timestamped values; expand them so no reading is lost.
            var seriesError: String?
            var series: [UUID: [SeriesValueExport]] = [:]
            if samples.contains(where: { $0.count > 1 }) {
                do {
                    let descriptor = HKQuantitySeriesSampleQueryDescriptor(predicate: .quantitySample(type: type, predicate: predicate),
                                                                           options: [.includeSample, .orderByQuantitySampleStartDate])
                    for try await result in descriptor.results(for: store) {
                        guard let parent = result.sample, parent.count > 1, let v = Self.value(result.quantity, unit) else { continue }
                        series[parent.uuid, default: []].append(SeriesValueExport(startDate: result.dateInterval.start, endDate: result.dateInterval.end, value: v))
                    }
                } catch {
                    seriesError = "series expansion failed: \(error.localizedDescription)"
                }
            }

            let exports = samples.compactMap { sample -> QuantitySampleExport? in
                guard let v = Self.value(sample.quantity, unit) else { return nil }
                let meta = Self.metadata(sample.metadata)
                return QuantitySampleExport(uuid: sample.uuid, startDate: sample.startDate, endDate: sample.endDate, value: v, count: sample.count,
                                            sourceName: sample.sourceRevision.source.name, sourceBundleIdentifier: sample.sourceRevision.source.bundleIdentifier,
                                            deviceName: sample.device?.name, metadata: meta.isEmpty ? nil : meta, series: series[sample.uuid])
            }
            let dropped = samples.count - exports.count
            let error = [seriesError, dropped > 0 ? "\(dropped) sample(s) with incompatible unit skipped" : nil].compactMap { $0 }.joined(separator: "; ")
            return QuantityTypeExport(typeIdentifier: type.identifier, unit: unit?.unitString ?? "", strategy: strategy, samples: exports,
                                      error: error.isEmpty ? nil : error)
        } catch {
            return QuantityTypeExport(typeIdentifier: type.identifier, unit: unit?.unitString ?? "", strategy: .associatedWithWorkout,
                                      samples: [], error: error.localizedDescription)
        }
    }
}
