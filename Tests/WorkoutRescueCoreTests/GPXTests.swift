import XCTest
@testable import WorkoutRescueCore

/// Minimal GPX 1.1 reader used to validate the exporter output as XML.
private final class GPXReader: NSObject, XMLParserDelegate {
    struct Point { var lat: String; var lon: String; var ele: String?; var time: String? }
    var segments: [[Point]] = []
    var elementPath: [String] = []
    var names: [String] = []
    var text = ""
    var rootAttributes: [String: String] = [:]

    static func read(_ data: Data) throws -> GPXReader {
        let reader = GPXReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldProcessNamespaces = true
        guard parser.parse() else { throw parser.parserError ?? NSError(domain: "GPX", code: 1) }
        return reader
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        elementPath.append(name)
        text = ""
        if name == "gpx" { rootAttributes = attributes; XCTAssertEqual(namespaceURI, "http://www.topografix.com/GPX/1/1") }
        if name == "trkseg" { segments.append([]) }
        if name == "trkpt" { segments[segments.count - 1].append(Point(lat: attributes["lat"] ?? "", lon: attributes["lon"] ?? "")) }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let parent = elementPath.dropLast().last
        if name == "ele", parent == "trkpt" { segments[segments.count - 1][segments[segments.count - 1].count - 1].ele = text }
        if name == "time", parent == "trkpt" { segments[segments.count - 1][segments[segments.count - 1].count - 1].time = text }
        if name == "name" { names.append(text) }
        elementPath.removeLast()
    }
}

final class GPXExporterTests: XCTestCase {
    private func point(_ t: Double, lat: Double, lon: Double, hAcc: Double = 5, alt: Double = 100, vAcc: Double = 3) -> RoutePointExport {
        RoutePointExport(timestamp: DemoData.referenceDate.addingTimeInterval(t), latitude: lat, longitude: lon, altitude: alt, ellipsoidalAltitude: nil,
                         horizontalAccuracy: hAcc, verticalAccuracy: vAcc, speed: -1, speedAccuracy: nil, course: -1, courseAccuracy: nil, floor: nil)
    }

    private func archive(routes: [[RoutePointExport]], source: String = "Apple Watch") throws -> WorkoutArchive {
        var archive = try XCTUnwrap(DemoData.archive(for: DemoData.rideUUID, routePointCount: 1))
        archive.isDemoData = false
        archive.workout.source.name = source
        archive.routes = routes.enumerated().map { i, points in
            RouteExport(uuid: DemoData.deterministicUUID(seed: 7, index: i), startDate: DemoData.referenceDate, endDate: DemoData.referenceDate,
                        expectedPointCount: points.count, metadata: [:], points: points, error: nil)
        }
        return archive
    }

    func testValidGPXWithMultipleRoutesPreservesOrderAndPrecision() throws {
        let a = try archive(routes: [[point(0, lat: 48.858_370_123_456_78, lon: 2.294_481_987_654_32), point(1, lat: 48.8584, lon: 2.2945)],
                                     [point(10, lat: 0.000_012_3, lon: -0.000_001), point(11, lat: -33.9, lon: 151.2)]])
        let data = try GPXExporter.export(a)
        let gpx = try GPXReader.read(data)
        XCTAssertEqual(gpx.rootAttributes["version"], "1.1")
        XCTAssertEqual(gpx.segments.count, 2)
        XCTAssertEqual(gpx.segments.map(\.count), [2, 2])
        XCTAssertEqual(Double(gpx.segments[0][0].lat), 48.858_370_123_456_78) // no rounding
        XCTAssertEqual(gpx.segments[1][0].lat, "0.0000123")                  // no exponent
        XCTAssertEqual(gpx.segments[1][0].lon, "-0.000001")
        XCTAssertEqual(gpx.segments[0][1].time, "2026-09-12T07:30:01.000Z")
        XCTAssertEqual(gpx.segments[0][0].ele, "100.0")
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("e-0"))
        XCTAssertFalse(text.contains("<extensions"))
    }

    func testEscapingAndUTF8() throws {
        let a = try archive(routes: [[point(0, lat: 45, lon: 6)]], source: "Félix's <Watch> & \"Ultra\" 🚴\u{0001}")
        let data = try GPXExporter.export(a)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("<src>Félix&apos;s &lt;Watch&gt; &amp; &quot;Ultra&quot; 🚴</src>"))
        XCTAssertNoThrow(try GPXReader.read(data))
    }

    func testInvalidPointsAreSkippedAndAltitudeOnlyWhenValid() throws {
        let a = try archive(routes: [[point(0, lat: 45, lon: 6, hAcc: -1), point(1, lat: .nan, lon: 6), point(2, lat: 95, lon: 6),
                                      point(3, lat: 45.1, lon: 6.1, vAcc: -1), point(4, lat: 45.2, lon: 6.2)]])
        let result = try GPXExporter.exportWithStats(a)
        XCTAssertEqual(result.writtenPointCount, 2)
        XCTAssertEqual(result.skippedPointCount, 3)
        let gpx = try GPXReader.read(result.data)
        XCTAssertNil(gpx.segments[0][0].ele)
        XCTAssertEqual(gpx.segments[0][1].ele, "100.0")
        XCTAssertTrue(String(decoding: result.data, as: UTF8.self).contains("Points skipped (invalid coordinate, kept in JSON): 3"))
    }

    func testMissingOrUnusableRoute() throws {
        XCTAssertThrowsError(try GPXExporter.export(try archive(routes: []))) { XCTAssertEqual($0 as? GPXExporter.ExportError, .noRoute) }
        XCTAssertThrowsError(try GPXExporter.export(try archive(routes: [[]]))) { XCTAssertEqual($0 as? GPXExporter.ExportError, .noRoute) }
        XCTAssertThrowsError(try GPXExporter.export(try archive(routes: [[point(0, lat: 1, lon: 1, hAcc: -1)]]))) {
            XCTAssertEqual($0 as? GPXExporter.ExportError, .noValidPoint)
        }
    }

    func testLongRouteIsNotTruncatedAndDemoIsLabelled() throws {
        let ride = DemoData.makeArchive(uuid: UUID(), activity: 13, start: DemoData.referenceDate, duration: 30_000, distance: 200_000,
                                        hasRoute: true, routePointCount: 30_000, heartRate: false, cycling: false, routeCount: 3)
        let data = try GPXExporter.export(ride)
        let gpx = try GPXReader.read(data)
        XCTAssertEqual(gpx.segments.flatMap { $0 }.count, 30_000)
        XCTAssertTrue(gpx.names.first?.hasPrefix("[DEMO – fictional data] Cycling") ?? false)
        // Timestamps strictly increasing inside each segment.
        for segment in gpx.segments { XCTAssertEqual(segment.map { $0.time! }, segment.map { $0.time! }.sorted()) }
    }

    func testDecimalFormatting() {
        XCTAssertEqual(GPXExporter.decimal(1e-5), "0.00001")
        XCTAssertEqual(GPXExporter.decimal(-2.5e-7), "-0.00000025")
        XCTAssertEqual(GPXExporter.decimal(48.85), "48.85")
        XCTAssertEqual(GPXExporter.decimal(-122.0), "-122.0")
    }
}
