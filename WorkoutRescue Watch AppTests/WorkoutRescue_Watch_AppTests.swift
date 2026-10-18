//
//  WorkoutRescue_Watch_AppTests.swift
//  WorkoutRescue Watch AppTests
//
//  Created by Félix Chevalier on 16/09/2026.
//
//  The portable logic is covered by `swift test` (Tests/WorkoutRescueCoreTests, run on macOS).
//  These on-watch tests cover what needs the watchOS SDK: HealthKit permission set and unit mapping.
//  They require a watchOS 26+ simulator runtime.

import XCTest
import HealthKit
@testable import WorkoutRescue_Watch_App

@MainActor
final class WorkoutRescue_Watch_AppTests: XCTestCase {
    func testPermissionSetIsReadOnlyAndMatchesExportedTypes() {
        let read = HealthArchiveReader.readTypes
        XCTAssertTrue(read.contains(HKObjectType.workoutType()))
        XCTAssertTrue(read.contains(HKSeriesType.workoutRoute()))
        XCTAssertEqual(read.count, HealthArchiveReader.quantityTypeIdentifiers.count + 2)
    }

    func testEveryRequestedTypeHasACompatibleUnit() throws {
        for identifier in HealthArchiveReader.quantityTypeIdentifiers {
            let unit = try XCTUnwrap(HealthArchiveReader.preferredUnit(for: identifier), identifier.rawValue)
            XCTAssertTrue(HKQuantityType(identifier).is(compatibleWith: unit), identifier.rawValue)
        }
    }

    func testActivityTableMatchesHealthKit() {
        let cases: [HKWorkoutActivityType] = [.cycling, .running, .walking, .hiking, .swimming, .handCycling, .highIntensityIntervalTraining, .other]
        for type in cases { XCTAssertFalse(ActivityTypeNames.name(for: type.rawValue).hasPrefix("Workout (type"), "\(type.rawValue)") }
        XCTAssertEqual(ActivityTypeNames.cycling, HKWorkoutActivityType.cycling.rawValue)
    }

    func testIncompatibleUnitNeverConverts() {
        XCTAssertNil(HealthArchiveReader.value(HKQuantity(unit: .meter(), doubleValue: 1), .kilocalorie()))
        XCTAssertEqual(HealthArchiveReader.value(HKQuantity(unit: .meter(), doubleValue: 1500), .meter()), 1500)
    }
}
