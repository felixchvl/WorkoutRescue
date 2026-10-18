import XCTest
@testable import WorkoutRescueCore

/// In-process fake receiver: each request is answered by the next scripted step.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Step { case respond(status: Int, body: (_ receivedBody: Data, _ request: URLRequest) -> Data); case fail(URLError.Code) }
    struct Record { let request: URLRequest; let body: Data }

    nonisolated(unsafe) static var steps: [Step] = []
    nonisolated(unsafe) static var records: [Record] = []
    static let lock = NSLock()

    static func reset(_ newSteps: [Step]) { lock.lock(); steps = newSteps; records = []; lock.unlock() }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(buffer, count: n) }
            stream.close()
        }
        Self.lock.lock()
        Self.records.append(Record(request: request, body: body))
        let step = Self.steps.isEmpty ? .fail(.resourceUnavailable) : Self.steps.removeFirst()
        Self.lock.unlock()
        switch step {
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .respond(let status, let makeBody):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: makeBody(body, request))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}

    /// Behaves like the real receiver: echoes the digest of what it actually received.
    static let honestReceipt: (Data, URLRequest) -> Data = { body, request in
        let parts = request.url!.pathComponents
        let json: [String: Any] = ["status": "stored", "uuid": parts[parts.count - 2], "kind": parts.last!,
                                   "sha256": RecoveryUploader.sha256Hex(body), "bytes": body.count, "path": "x"]
        return try! JSONSerialization.data(withJSONObject: json)
    }
}

final class RecoveryEndpointTests: XCTestCase {
    func testParsing() throws {
        XCTAssertEqual(try RecoveryEndpoint.parse("rescue.example.org").baseURL.absoluteString, "https://rescue.example.org")
        XCTAssertEqual(try RecoveryEndpoint.parse("  HTTPS://rescue.example.org/base/ ").baseURL.absoluteString, "https://rescue.example.org/base")
        XCTAssertEqual(try RecoveryEndpoint.parse("https://u:p@rescue.example.org:8443/?q=1#f").baseURL.absoluteString, "https://rescue.example.org:8443")
        XCTAssertThrowsError(try RecoveryEndpoint.parse("http://rescue.example.org")) { XCTAssertEqual($0 as? RecoveryEndpoint.ParseError, .insecureScheme) }
        XCTAssertThrowsError(try RecoveryEndpoint.parse("http://localhost:8787")) { XCTAssertEqual($0 as? RecoveryEndpoint.ParseError, .insecureScheme) }
        XCTAssertNoThrow(try RecoveryEndpoint.parse("http://127.0.0.1:8787", allowInsecureLoopback: true))
        XCTAssertThrowsError(try RecoveryEndpoint.parse("http://192.168.1.2", allowInsecureLoopback: true))
        XCTAssertThrowsError(try RecoveryEndpoint.parse("   ")) { XCTAssertEqual($0 as? RecoveryEndpoint.ParseError, .empty) }
        XCTAssertThrowsError(try RecoveryEndpoint.parse("ftp://x.org"))
        XCTAssertEqual(try RecoveryEndpoint.parse("rescue.example.org").url("/api/ping").absoluteString, "https://rescue.example.org/api/ping")
    }
}

final class RecoveryUploaderTests: XCTestCase {
    final class Delays: @unchecked Sendable { var values: [Duration] = []; let lock = NSLock()
        func add(_ d: Duration) { lock.lock(); values.append(d); lock.unlock() } }

    let uuid = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    let payload = Data(repeating: 0x41, count: 200_000)

    func makeUploader(_ delays: Delays = Delays(), attempts: Int = 4) throws -> RecoveryUploader {
        RecoveryUploader(endpoint: try RecoveryEndpoint.parse("https://rescue.example.org"), token: " TOKEN-123 ", session: StubURLProtocol.session(),
                         retry: RetryPolicy(maxAttempts: attempts), sleeper: { delays.add($0) })
    }

    func testSuccessfulUploadSendsAuthDigestAndVerifiesReceipt() async throws {
        StubURLProtocol.reset([.respond(status: 201, body: StubURLProtocol.honestReceipt)])
        let receipt = try await makeUploader().upload(payload, kind: .metadata, workoutUUID: uuid)
        XCTAssertEqual(receipt.sha256, RecoveryUploader.sha256Hex(payload))
        let record = try XCTUnwrap(StubURLProtocol.records.first)
        XCTAssertEqual(record.request.httpMethod, "POST")
        XCTAssertEqual(record.request.url?.path, "/api/workouts/\(uuid.uuidString)/metadata")
        XCTAssertEqual(record.request.value(forHTTPHeaderField: "Authorization"), "Bearer TOKEN-123")
        XCTAssertEqual(record.request.value(forHTTPHeaderField: "X-WorkoutRescue-SHA256"), RecoveryUploader.sha256Hex(payload))
        XCTAssertEqual(record.request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(record.body, payload)
    }

    func test401IsNotRetried() async throws {
        StubURLProtocol.reset([.respond(status: 401, body: { _, _ in Data(#"{"error":"unauthorized"}"#.utf8) })])
        do { _ = try await makeUploader().upload(payload, kind: .route, workoutUUID: uuid); XCTFail("must throw") }
        catch { XCTAssertEqual(error as? UploadError, .unauthorized) }
        XCTAssertEqual(StubURLProtocol.records.count, 1)
    }

    func test500ThenSuccessIsRetriedWithBackoff() async throws {
        let delays = Delays()
        StubURLProtocol.reset([.respond(status: 500, body: { _, _ in Data() }), .respond(status: 503, body: { _, _ in Data() }),
                               .respond(status: 200, body: StubURLProtocol.honestReceipt)])
        let receipt = try await makeUploader(delays).upload(payload, kind: .metadata, workoutUUID: uuid)
        XCTAssertEqual(receipt.bytes, payload.count)
        XCTAssertEqual(StubURLProtocol.records.count, 3)
        XCTAssertEqual(delays.values, [.seconds(1), .seconds(2)])
    }

    func testTimeoutAndLostConnectionAreRetried() async throws {
        StubURLProtocol.reset([.fail(.timedOut), .fail(.networkConnectionLost), .respond(status: 201, body: StubURLProtocol.honestReceipt)])
        _ = try await makeUploader().upload(payload, kind: .metadata, workoutUUID: uuid)
        XCTAssertEqual(StubURLProtocol.records.count, 3)
    }

    func testPersistentNetworkFailureSurfacesAfterMaxAttempts() async throws {
        StubURLProtocol.reset(Array(repeating: .fail(.notConnectedToInternet), count: 5))
        do { _ = try await makeUploader(attempts: 3).upload(payload, kind: .metadata, workoutUUID: uuid); XCTFail("must throw") }
        catch { guard case .network(let code, _)? = error as? UploadError else { return XCTFail("\(error)") }
                XCTAssertEqual(code, URLError.Code.notConnectedToInternet.rawValue) }
        XCTAssertEqual(StubURLProtocol.records.count, 3)
    }

    func testUntrustedCertificateIsNotRetried() async throws {
        StubURLProtocol.reset([.fail(.serverCertificateUntrusted)])
        do { _ = try await makeUploader().upload(payload, kind: .metadata, workoutUUID: uuid); XCTFail("must throw") } catch {}
        XCTAssertEqual(StubURLProtocol.records.count, 1)
    }

    func testInterruptedUploadDetectedByServerIsRetried() async throws {
        // Server saw a truncated body: digest mismatch (400) — the watch resends the full file.
        StubURLProtocol.reset([.respond(status: 400, body: { _, _ in Data(#"{"error":"sha256_mismatch"}"#.utf8) }),
                               .respond(status: 201, body: StubURLProtocol.honestReceipt)])
        _ = try await makeUploader().upload(payload, kind: .metadata, workoutUUID: uuid)
        XCTAssertEqual(StubURLProtocol.records.count, 2)
    }

    func testWrongServerDigestIsNeverReportedAsSuccess() async throws {
        let lying: (Data, URLRequest) -> Data = { body, request in
            var receipt = try! JSONSerialization.jsonObject(with: StubURLProtocol.honestReceipt(body, request)) as! [String: Any]
            receipt["sha256"] = String(repeating: "0", count: 64)
            return try! JSONSerialization.data(withJSONObject: receipt)
        }
        StubURLProtocol.reset(Array(repeating: .respond(status: 201, body: lying), count: 4))
        do { _ = try await makeUploader().upload(payload, kind: .metadata, workoutUUID: uuid); XCTFail("must throw") }
        catch { XCTAssertEqual(error as? UploadError, .integrityMismatch) }
        XCTAssertEqual(StubURLProtocol.records.count, 4)
    }

    func testGarbageResponseIsInvalid() async throws {
        StubURLProtocol.reset([.respond(status: 200, body: { _, _ in Data("<html>proxy</html>".utf8) })])
        do { _ = try await makeUploader().upload(payload, kind: .metadata, workoutUUID: uuid); XCTFail("must throw") }
        catch { XCTAssertEqual(error as? UploadError, .invalidResponse) }
    }

    func testPing() async throws {
        StubURLProtocol.reset([.respond(status: 200, body: { _, _ in Data(#"{"ok":true,"service":"workoutrescue-receiver","protocol_version":1,"max_bytes":10}"#.utf8) })])
        let result = try await makeUploader().ping()
        XCTAssertEqual(result.protocolVersion, 1)
        XCTAssertEqual(StubURLProtocol.records.first?.request.url?.path, "/api/ping")
    }
}

final class PipelineAndLedgerTests: XCTestCase {
    func uploader() throws -> RecoveryUploader {
        RecoveryUploader(endpoint: try RecoveryEndpoint.parse("https://rescue.example.org"), token: "t", session: StubURLProtocol.session(),
                         retry: RetryPolicy(maxAttempts: 2), sleeper: { _ in })
    }

    func testBothFilesUploadedJSONFirst() async throws {
        StubURLProtocol.reset([.respond(status: 201, body: StubURLProtocol.honestReceipt), .respond(status: 201, body: StubURLProtocol.honestReceipt)])
        let archive = try XCTUnwrap(DemoData.archive(for: DemoData.rideUUID, routePointCount: 500))
        let result = try await WorkoutUploadPipeline(uploader: uploader()).export(archive, selection: .both)
        XCTAssertEqual(StubURLProtocol.records.map { $0.request.url!.lastPathComponent }, ["metadata", "route"])
        XCTAssertEqual(result.routeStatus, .uploaded)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(try JSONExporter.decode(StubURLProtocol.records[0].body), archive)
        XCTAssertTrue(String(decoding: StubURLProtocol.records[1].body, as: UTF8.self).hasPrefix("<?xml"))
    }

    func testWorkoutWithoutRouteIsCompleteWithJSONOnly() async throws {
        StubURLProtocol.reset([.respond(status: 201, body: StubURLProtocol.honestReceipt)])
        let archive = try XCTUnwrap(DemoData.archive(for: DemoData.indoorRideUUID))
        let result = try await WorkoutUploadPipeline(uploader: uploader()).export(archive, selection: .both)
        XCTAssertEqual(StubURLProtocol.records.count, 1)
        XCTAssertEqual(result.routeStatus, .noRoute)
        XCTAssertTrue(result.isComplete)
    }

    func testGPXOnlyWithoutRouteFails() async throws {
        StubURLProtocol.reset([])
        let archive = try XCTUnwrap(DemoData.archive(for: DemoData.indoorRideUUID))
        do { _ = try await WorkoutUploadPipeline(uploader: uploader()).export(archive, selection: .gpx); XCTFail("must throw") }
        catch { XCTAssertEqual(error as? GPXExporter.ExportError, .noRoute) }
        XCTAssertTrue(StubURLProtocol.records.isEmpty)
    }

    func testFailedRouteUploadDoesNotClaimCompletion() async throws {
        StubURLProtocol.reset([.respond(status: 201, body: StubURLProtocol.honestReceipt), .respond(status: 401, body: { _, _ in Data() })])
        let archive = try XCTUnwrap(DemoData.archive(for: DemoData.rideUUID, routePointCount: 50))
        do { _ = try await WorkoutUploadPipeline(uploader: uploader()).export(archive, selection: .both); XCTFail("must throw") }
        catch { XCTAssertEqual(error as? UploadError, .unauthorized) }
    }

    @MainActor
    func testLedgerPersistsAndMerges() throws {
        let suite = "WorkoutRescueTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let uuid = DemoData.rideUUID
        let receipt = UploadReceipt(status: "stored", uuid: uuid.uuidString, kind: "metadata", sha256: "ab", bytes: 2, path: nil)
        let ledger = ExportLedger(defaults: defaults)
        ledger.record(WorkoutExportResult(workoutUUID: uuid, metadata: receipt, route: nil, routeStatus: .notRequested, jsonBytes: 2, gpxBytes: nil, finishedAt: .now))
        XCTAssertFalse(ledger.isComplete(uuid))
        let routeReceipt = UploadReceipt(status: "stored", uuid: uuid.uuidString, kind: "route", sha256: "cd", bytes: 3, path: nil)
        ledger.record(WorkoutExportResult(workoutUUID: uuid, metadata: nil, route: routeReceipt, routeStatus: .uploaded, jsonBytes: 0, gpxBytes: 3, finishedAt: .now))
        let reloaded = ExportLedger(defaults: defaults)
        XCTAssertTrue(reloaded.isComplete(uuid))
        XCTAssertEqual(reloaded.result(for: uuid)?.metadata, receipt)
        XCTAssertEqual(reloaded.result(for: uuid)?.route, routeReceipt)
    }
}
