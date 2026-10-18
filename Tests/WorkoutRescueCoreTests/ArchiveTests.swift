import XCTest
@testable import WorkoutRescueCore

final class ArchiveDateCodingTests: XCTestCase {
    func testMicrosecondRoundTrip() throws {
        for interval in [0.0, 1.5, 1_757_660_400.123456, 1_757_660_400.999_999_7, -86_400.25, 4_102_444_799.000001] {
            let date = Date(timeIntervalSince1970: interval)
            let text = ArchiveDateCoding.string(from: date)
            XCTAssertTrue(text.hasSuffix("Z"), text)
            XCTAssertEqual(text.count, 27, text)
            let parsed = try XCTUnwrap(ArchiveDateCoding.date(from: text), text)
            XCTAssertEqual(parsed.timeIntervalSince1970, interval, accuracy: 0.000_001, text)
        }
        XCTAssertEqual(ArchiveDateCoding.string(from: Date(timeIntervalSince1970: 1_757_660_400.5)), "2025-09-12T07:00:00.500000Z")
    }

    func testParsesOffsetsAndRejectsGarbage() throws {
        let utc = try XCTUnwrap(ArchiveDateCoding.date(from: "2026-09-12T07:30:00Z"))
        let paris = try XCTUnwrap(ArchiveDateCoding.date(from: "2026-09-12T09:30:00.000+02:00"))
        XCTAssertEqual(utc, paris)
        for bad in ["", "2026-09-12", "2026-09-12T07:30:00", "2026-09-12T07:30:00.Z", "2026-09-12T07:30:00Zjunk", "abcd-09-12T07:30:00Z"] {
            XCTAssertNil(ArchiveDateCoding.date(from: bad), bad)
        }
    }
}

final class JSONArchiveTests: XCTestCase {
    func testRoundTripLongRideIsLossless() throws {
        let archive = DemoData.makeArchive(uuid: UUID(), activity: 13, start: DemoData.referenceDate, duration: 20_000, distance: 150_000,
                                           hasRoute: true, routePointCount: 20_000, heartRate: true, cycling: true, routeCount: 2)
        XCTAssertEqual(archive.totalRoutePointCount, 20_000)
        let data = try JSONExporter.export(archive)
        let decoded = try JSONExporter.decode(data)
        XCTAssertEqual(decoded, archive)
        XCTAssertEqual(decoded.routes.map(\.points.count), [10_000, 10_000])
        XCTAssertEqual(decoded.routes[0].points[1234], archive.routes[0].points[1234])
        // Compact encoding stays reasonable for a watch: < 600 bytes per GPS point all included.
        XCTAssertLessThan(data.count, 20_000 * 600)
    }

    func testHeaderFieldsAndDemoFlag() throws {
        let archive = try XCTUnwrap(DemoData.archive(for: DemoData.rideUUID, routePointCount: 10))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONExporter.export(archive)) as? [String: Any])
        XCTAssertEqual(object["format"] as? String, "workoutrescue.workout")
        XCTAssertEqual(object["schemaVersion"] as? Int, 2)
        XCTAssertEqual(object["isDemoData"] as? Bool, true)
        let workout = try XCTUnwrap(object["workout"] as? [String: Any])
        XCTAssertEqual((workout["activityType"] as? [String: Any])?["name"] as? String, "Cycling")
        XCTAssertEqual(workout["startDate"] as? String, "2026-09-12T07:30:00.000000Z")
        let point = try XCTUnwrap(((object["routes"] as? [[String: Any]])?.first?["points"] as? [[String: Any]])?.first)
        XCTAssertEqual(point["timestamp"] as? String, "2026-09-12T07:30:00.250000Z")
        for key in ["latitude", "longitude", "altitude", "horizontalAccuracy", "verticalAccuracy", "speed", "course"] {
            XCTAssertNotNil(point[key], key)
        }
    }

    func testNonFiniteValuesDoNotBreakExport() throws {
        var archive = try XCTUnwrap(DemoData.archive(for: DemoData.rideUUID, routePointCount: 3))
        archive.routes[0].points[0].altitude = .nan
        archive.routes[0].points[1].speed = .infinity
        archive.workout.metadata["weird"] = .double(-.infinity)
        let decoded = try JSONExporter.decode(JSONExporter.export(archive))
        XCTAssertTrue(decoded.routes[0].points[0].altitude.isNaN)
        XCTAssertEqual(decoded.routes[0].points[1].speed, .infinity)
        XCTAssertEqual(decoded.workout.metadata["weird"], .double(-.infinity))
    }

    func testWorkoutWithoutRouteAndWithoutHeartRate() throws {
        let indoor = try XCTUnwrap(DemoData.archive(for: DemoData.indoorRideUUID))
        XCTAssertTrue(indoor.routes.isEmpty)
        XCTAssertEqual(try JSONExporter.decode(JSONExporter.export(indoor)), indoor)
        let run = try XCTUnwrap(DemoData.archive(for: DemoData.runUUID))
        XCTAssertEqual(run.sampleCount(for: "HKQuantityTypeIdentifierHeartRate"), 0)
        XCTAssertEqual(try JSONExporter.decode(JSONExporter.export(run)), run)
    }

    func testTypedMetadataConversionAndRoundTrip() throws {
        XCTAssertEqual(MetadataValue.from(NSNumber(value: true)), .bool(true))
        XCTAssertEqual(MetadataValue.from(NSNumber(value: 42)), .integer(42))
        XCTAssertEqual(MetadataValue.from(NSNumber(value: 21.5)), .double(21.5))
        XCTAssertEqual(MetadataValue.from("Europe/Paris"), .string("Europe/Paris"))
        let date = Date(timeIntervalSince1970: 1_700_000_000.25)
        XCTAssertEqual(MetadataValue.from(date), .date(date))
        if case .unsupported(let typeName, _) = MetadataValue.from([1, 2]) { XCTAssertFalse(typeName.isEmpty) } else { XCTFail() }

        var archive = try XCTUnwrap(DemoData.archive(for: DemoData.runUUID, routePointCount: 2))
        archive.workout.metadata = [
            "s": .string("é<&>\"'\u{1F6B4}"), "i": .integer(.max), "d": .double(0.1), "b": .bool(false), "t": .date(date),
            "q": .quantity(value: 21.3, unit: "degC", description: "21.3 degC"), "u": .unsupported(typeName: "NSData", description: "<00>"),
        ]
        XCTAssertEqual(try JSONExporter.decode(JSONExporter.export(archive)).workout.metadata, archive.workout.metadata)
    }

    func testUnknownMetadataTypeDecodesAsUnsupported() throws {
        let json = #"{"type":"futureType","value":1}"#
        let value = try JSONDecoder().decode(MetadataValue.self, from: Data(json.utf8))
        XCTAssertEqual(value, .unsupported(typeName: "unknown", description: ""))
    }

    func testRouteCompletenessFlag() throws {
        var route = try XCTUnwrap(DemoData.archive(for: DemoData.rideUUID, routePointCount: 10)?.routes.first)
        XCTAssertTrue(route.isComplete)
        route.expectedPointCount = 11
        XCTAssertFalse(route.isComplete)
        route.expectedPointCount = 10
        route.error = "interrupted"
        XCTAssertFalse(route.isComplete)
    }
}

final class ActivityTypeNamesTests: XCTestCase {
    func testKnownValues() {
        XCTAssertEqual(ActivityTypeNames.name(for: 13), "Cycling")
        XCTAssertEqual(ActivityTypeNames.name(for: 37), "Running")
        XCTAssertEqual(ActivityTypeNames.name(for: 52), "Walking")
        XCTAssertEqual(ActivityTypeNames.name(for: 46), "Swimming")
        XCTAssertEqual(ActivityTypeNames.name(for: 74), "Hand Cycling")
        XCTAssertEqual(ActivityTypeNames.name(for: 9999), "Workout (type 9999)")
    }
}
