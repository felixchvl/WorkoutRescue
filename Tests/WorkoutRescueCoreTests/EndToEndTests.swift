import XCTest
@testable import WorkoutRescueCore

/// Runs only when `scripts/e2e.sh` started a real receiver (plain HTTP on loopback, test only).
/// Exercises the shipping uploader against `receiver/server.py`, then re-reads the stored files.
final class EndToEndTests: XCTestCase {
    var env: [String: String] { ProcessInfo.processInfo.environment }

    func configuration() throws -> (RecoveryEndpoint, String, URL) {
        guard let url = env["WR_E2E_URL"], let token = env["WR_E2E_TOKEN"], let dir = env["WR_E2E_EXPORT_DIR"] else {
            throw XCTSkip("Set WR_E2E_URL / WR_E2E_TOKEN / WR_E2E_EXPORT_DIR (see scripts/e2e.sh).")
        }
        return (try RecoveryEndpoint.parse(url, allowInsecureLoopback: true), token, URL(fileURLWithPath: dir))
    }

    func uploader(_ endpoint: RecoveryEndpoint, _ token: String) -> RecoveryUploader {
        RecoveryUploader(endpoint: endpoint, token: token, retry: RetryPolicy(maxAttempts: 2, baseDelay: .milliseconds(50)))
    }

    func testFullChainWithRealReceiver() async throws {
        let (endpoint, token, exportDir) = try configuration()
        let client = uploader(endpoint, token)
        let ping = try await client.ping()
        XCTAssertTrue(ping.ok)

        let ride = DemoData.makeArchive(uuid: UUID(), activity: 13, start: DemoData.referenceDate, duration: 14_400, distance: 110_000,
                                        hasRoute: true, routePointCount: 14_400, heartRate: true, cycling: true, routeCount: 2)
        let indoor = try XCTUnwrap(DemoData.archive(for: DemoData.indoorRideUUID))
        let pipeline = WorkoutUploadPipeline(uploader: client)
        for archive in [ride, indoor] {
            let payloads = try ExportPayloads.build(from: archive)
            let result = try await pipeline.export(archive, selection: .both)
            XCTAssertTrue(result.isComplete)
            let folder = exportDir.appendingPathComponent(archive.workout.uuid.uuidString)
            let storedJSON = try Data(contentsOf: folder.appendingPathComponent("workout.json"))
            XCTAssertEqual(storedJSON, payloads.json, "receiver must store the bytes unchanged")
            XCTAssertEqual(try JSONExporter.decode(storedJSON), archive, "re-read archive must equal the source data")
            if let gpx = payloads.gpx {
                XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("route.gpx")), gpx)
                XCTAssertEqual(result.route?.sha256, RecoveryUploader.sha256Hex(gpx))
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("route.gpx").path))
                XCTAssertEqual(result.routeStatus, .noRoute)
            }
            // Retrying the same export is idempotent: the server answers "duplicate", nothing is overwritten.
            let again = try await pipeline.export(archive, selection: .json)
            XCTAssertEqual(again.metadata?.status, "duplicate")
        }

        // A different file for the same workout is stored as a revision, never overwriting the first one.
        var changed = indoor
        changed.exportedAt = changed.exportedAt.addingTimeInterval(1)
        let revision = try await pipeline.export(changed, selection: .json)
        XCTAssertEqual(revision.metadata?.status, "stored_revision")
        let original = try Data(contentsOf: exportDir.appendingPathComponent(indoor.workout.uuid.uuidString).appendingPathComponent("workout.json"))
        XCTAssertEqual(try JSONExporter.decode(original), indoor)
    }

    func testWrongTokenIsRejected() async throws {
        let (endpoint, _, _) = try configuration()
        do { _ = try await uploader(endpoint, "WRONG-TOKEN").ping(); XCTFail("must throw") }
        catch { XCTAssertEqual(error as? UploadError, .unauthorized) }
    }
}
