import Foundation

/// Fictional workouts for Demo Mode, App Review and tests. Never read from or written to HealthKit.
/// Every archive built here has `isDemoData == true`, its source is named "WorkoutRescue Demo
/// (fictional data)", and the GPX name starts with "[DEMO – fictional data]".
nonisolated enum DemoData {
    static let sourceName = "WorkoutRescue Demo (fictional data)"

    static let rideUUID = UUID(uuidString: "D3E00000-0000-4000-8000-000000000001")!
    static let indoorRideUUID = UUID(uuidString: "D3E00000-0000-4000-8000-000000000002")!
    static let runUUID = UUID(uuidString: "D3E00000-0000-4000-8000-000000000003")!

    /// Fixed reference date so that demo exports are reproducible.
    static let referenceDate = ArchiveDateCoding.date(from: "2026-09-12T07:30:00.000000Z")!

    static var summaries: [WorkoutSummary] {
        [rideUUID, runUUID, indoorRideUUID].compactMap { archive(for: $0) }.map { a in
            WorkoutSummary(id: a.workout.uuid, activityTypeRawValue: a.workout.activityType.rawValue, startDate: a.workout.startDate,
                           endDate: a.workout.endDate, duration: a.workout.durationSeconds, totalDistanceMeters: a.workout.totalDistance?.value,
                           totalActiveEnergyKilocalories: a.workout.totalEnergyBurned?.value, sourceName: sourceName, isDemoData: true)
        }.sorted { $0.startDate > $1.startDate }
    }

    static func archive(for uuid: UUID, routePointCount: Int = 5_400) -> WorkoutArchive? {
        switch uuid {
        case rideUUID:
            return makeArchive(uuid: uuid, activity: ActivityTypeNames.cycling, start: referenceDate, duration: Double(routePointCount),
                               distance: Double(routePointCount) * 7.5, hasRoute: true, routePointCount: routePointCount, heartRate: true, cycling: true)
        case indoorRideUUID:
            return makeArchive(uuid: uuid, activity: ActivityTypeNames.cycling, start: referenceDate.addingTimeInterval(-86_400), duration: 2_700,
                               distance: 18_000, hasRoute: false, routePointCount: 0, heartRate: true, cycling: true)
        case runUUID:
            return makeArchive(uuid: uuid, activity: 37, start: referenceDate.addingTimeInterval(86_400), duration: 1_800,
                               distance: 5_200, hasRoute: true, routePointCount: 1_800, heartRate: false, cycling: false)
        default:
            return nil
        }
    }

    /// Builds a deterministic fictional workout. `routePointCount` at 1 Hz.
    static func makeArchive(uuid: UUID, activity: UInt, start: Date, duration: Double, distance: Double, hasRoute: Bool,
                            routePointCount: Int, heartRate: Bool, cycling: Bool, routeCount: Int = 1) -> WorkoutArchive {
        let end = start.addingTimeInterval(duration)
        var types: [QuantityTypeExport] = []
        if heartRate {
            let samples = stride(from: 0.0, to: duration, by: 5).enumerated().map { index, offset in
                QuantitySampleExport(uuid: deterministicUUID(seed: 1, index: index), startDate: start.addingTimeInterval(offset),
                                     endDate: start.addingTimeInterval(offset), value: 120 + 25 * sin(offset / 300), count: 1,
                                     sourceName: sourceName, sourceBundleIdentifier: nil, deviceName: "Demo Watch", metadata: nil, series: nil)
            }
            types.append(QuantityTypeExport(typeIdentifier: "HKQuantityTypeIdentifierHeartRate", unit: "count/min", strategy: .demo, samples: samples, error: nil))
        }
        if cycling {
            let power = stride(from: 0.0, to: duration, by: 10).enumerated().map { index, offset in
                QuantitySampleExport(uuid: deterministicUUID(seed: 2, index: index), startDate: start.addingTimeInterval(offset),
                                     endDate: start.addingTimeInterval(offset + 10), value: 180 + 40 * cos(offset / 200), count: 1,
                                     sourceName: sourceName, sourceBundleIdentifier: nil, deviceName: nil, metadata: nil, series: nil)
            }
            types.append(QuantityTypeExport(typeIdentifier: "HKQuantityTypeIdentifierCyclingPower", unit: "W", strategy: .demo, samples: power, error: nil))
            let distanceSeries = (0..<min(600, Int(duration))).map { i in
                SeriesValueExport(startDate: start.addingTimeInterval(Double(i)), endDate: start.addingTimeInterval(Double(i + 1)), value: 7.5)
            }
            types.append(QuantityTypeExport(
                typeIdentifier: "HKQuantityTypeIdentifierDistanceCycling", unit: "m", strategy: .demo,
                samples: [QuantitySampleExport(uuid: deterministicUUID(seed: 3, index: 0), startDate: start, endDate: start.addingTimeInterval(Double(distanceSeries.count)),
                                               value: Double(distanceSeries.count) * 7.5, count: distanceSeries.count, sourceName: sourceName,
                                               sourceBundleIdentifier: nil, deviceName: nil, metadata: ["HKMetadataKeyDemo": .bool(true)], series: distanceSeries)],
                error: nil))
        }
        var routes: [RouteExport] = []
        if hasRoute {
            let perRoute = routePointCount / max(1, routeCount)
            for r in 0..<routeCount {
                let points = (0..<perRoute).map { i -> RoutePointExport in
                    let global = Double(r * perRoute + i)
                    let angle = global / Double(max(routePointCount, 1)) * 2 * .pi
                    // Fictional loop of ~6 km radius around a fixed point; values are not a real person's location.
                    return RoutePointExport(timestamp: start.addingTimeInterval(global + 0.25), latitude: 45.0 + 0.05 * sin(angle),
                                            longitude: 6.0 + 0.07 * cos(angle), altitude: 400 + 50 * sin(angle * 3), ellipsoidalAltitude: 450 + 50 * sin(angle * 3),
                                            horizontalAccuracy: 4.5, verticalAccuracy: 3.0, speed: 7.5, speedAccuracy: 0.5,
                                            course: (angle * 180 / .pi + 90).truncatingRemainder(dividingBy: 360), courseAccuracy: 5, floor: nil)
                }
                routes.append(RouteExport(uuid: deterministicUUID(seed: 9, index: r), startDate: points.first?.timestamp ?? start,
                                          endDate: points.last?.timestamp ?? end, expectedPointCount: points.count,
                                          metadata: ["HKMetadataKeyDemo": .bool(true)], points: points, error: nil))
            }
        }
        let record = WorkoutRecord(
            uuid: uuid, activityType: ActivityTypeExport(rawValue: activity), startDate: start, endDate: end, durationSeconds: duration,
            totalDistance: MeasuredValue(value: distance, unit: "m"), totalEnergyBurned: MeasuredValue(value: duration / 6, unit: "kcal"),
            totalSwimmingStrokeCount: nil, totalFlightsClimbed: nil,
            source: SourceExport(name: sourceName, bundleIdentifier: nil, version: nil, productType: nil, operatingSystemVersion: nil),
            device: DeviceExport(name: "Demo Watch", manufacturer: "Fictional", model: "Demo", hardwareVersion: nil, firmwareVersion: nil,
                                 softwareVersion: nil, localIdentifier: nil, udiDeviceIdentifier: nil),
            metadata: ["HKMetadataKeyIndoorWorkout": .bool(!hasRoute), "HKMetadataKeyTimeZone": .string("Europe/Paris"),
                       "HKMetadataKeyElevationAscended": .quantity(value: 312, unit: "m", description: "312 m")],
            statistics: [StatisticsExport(typeIdentifier: "HKQuantityTypeIdentifierHeartRate", unit: "count/min", startDate: start, endDate: end,
                                          sum: nil, average: heartRate ? 120 : nil, minimum: heartRate ? 95 : nil, maximum: heartRate ? 145 : nil, mostRecent: nil)],
            activities: [], events: [WorkoutEventExport(typeRawValue: 1, typeName: "pause", startDate: start.addingTimeInterval(600),
                                                       endDate: start.addingTimeInterval(600), metadata: [:]),
                                    WorkoutEventExport(typeRawValue: 2, typeName: "resume", startDate: start.addingTimeInterval(660),
                                                       endDate: start.addingTimeInterval(660), metadata: [:])])
        return WorkoutArchive(exportedAt: referenceDate.addingTimeInterval(7 * 86_400),
                              exporter: ExporterInfo(appVersion: "demo", appBuild: nil, platform: "demo", operatingSystemVersion: nil),
                              isDemoData: true, workout: record, quantityTypes: types, routes: routes,
                              warnings: hasRoute ? [] : ["No GPS route for this workout (fictional indoor ride)."])
    }

    static func deterministicUUID(seed: Int, index: Int) -> UUID {
        // UInt64 arithmetic: `Int` is 32-bit on arm64_32 watches.
        let value = UInt64(index)
        return UUID(uuidString: String(format: "D3E%05llX-%04llX-4000-8000-%012llX", UInt64(seed) & 0xFFFFF, (value >> 48) & 0xFFFF, value & 0xFFFF_FFFF_FFFF))!
    }
}
