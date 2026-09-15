//
//  WorkoutRescue_Watch_AppTests.swift
//  WorkoutRescue Watch AppTests
//
//  Created by Félix Chevalier on 16/09/2026.
//

import XCTest
@testable import WorkoutRescue_Watch_App

final class WorkoutRescue_Watch_AppTests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testJSONSchemaVersion() throws {
        let export = WorkoutExport(workout: WorkoutExportIdentity(uuid: UUID(), activityTypeRawValue: 1, sourceName: nil, sourceBundleIdentifier: nil), summary: WorkoutExportSummary(startDate: .now, endDate: .now, durationSeconds: 0, totalDistanceMeters: nil, activeEnergyKilocalories: nil), metadata: [:], quantitySamples: [], routes: [])
        let data = try JSONExporter.export(export)
        XCTAssertTrue(try XCTUnwrap(String(data: data, encoding: .utf8)).contains("\"schemaVersion\" : 1"))
        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // Any test you write for XCTest can be annotated as throws and async.
        // Mark your test throws to produce an unexpected failure when your test encounters an uncaught error.
        // Mark your test async to allow awaiting for asynchronous code to complete. Check the results with assertions afterwards.
        // XCTest Documentation
        // https://developer.apple.com/documentation/xctest
    }

    func testGPXRejectsMissingRoute() throws {
        let export = WorkoutExport(workout: WorkoutExportIdentity(uuid: UUID(), activityTypeRawValue: 1, sourceName: nil, sourceBundleIdentifier: nil), summary: WorkoutExportSummary(startDate: .now, endDate: .now, durationSeconds: 0, totalDistanceMeters: nil, activeEnergyKilocalories: nil), metadata: [:], quantitySamples: [], routes: [])
        XCTAssertThrowsError(try GPXExporter.export(export))
    }

}
