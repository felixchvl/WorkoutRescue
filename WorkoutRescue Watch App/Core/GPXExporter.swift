import Foundation

enum GPXExporter {
    enum ExportError: LocalizedError { case noRoute
        var errorDescription: String? { "This workout does not contain GPS route data." }
    }

    static func export(_ workout: WorkoutExport) throws -> Data {
        guard workout.routes.contains(where: { !$0.points.isEmpty }) else { throw ExportError.noRoute }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var xml = ["<?xml version=\"1.0\" encoding=\"UTF-8\"?>", "<gpx version=\"1.1\" creator=\"Workout Rescue\" xmlns=\"http://www.topografix.com/GPX/1/1\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xsi:schemaLocation=\"http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd\">", "<trk><name>\(escape(workout.workout.uuid.uuidString))</name>"]
        for route in workout.routes where !route.points.isEmpty {
            xml.append("<trkseg>")
            for point in route.points {
                xml.append("<trkpt lat=\"\(point.latitude)\" lon=\"\(point.longitude)\">")
                if let altitude = point.altitude { xml.append("<ele>\(altitude)</ele>") }
                xml.append("<time>\(formatter.string(from: point.timestamp))</time></trkpt>")
            }
            xml.append("</trkseg>")
        }
        xml.append("</trk></gpx>")
        return Data(xml.joined(separator: "\n").utf8)
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
