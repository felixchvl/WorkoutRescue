import Foundation

/// GPX 1.1 (http://www.topografix.com/GPX/1/1) writer. Standard elements only, no extensions:
/// biometric data stays in the JSON archive, which is the source of truth.
///
/// - one `<trk>` per workout, one `<trkseg>` per `HKWorkoutRoute` (in route order);
/// - points keep HealthKit order; lat/lon are written without exponent and without rounding
///   (shortest round-trip representation of the Double);
/// - points with an invalid coordinate (negative horizontal accuracy, non-finite or out of range)
///   are skipped and counted in `<desc>`; they remain in the JSON;
/// - `<ele>` is written only when the vertical accuracy marks the altitude as valid.
nonisolated enum GPXExporter {
    enum ExportError: LocalizedError, Equatable {
        case noRoute
        case noValidPoint
        var errorDescription: String? {
            switch self {
            case .noRoute: return "This workout has no GPS route in HealthKit."
            case .noValidPoint: return "The GPS route contains no valid coordinate."
            }
        }
    }

    struct Result: Sendable {
        let data: Data
        let writtenPointCount: Int
        let skippedPointCount: Int
    }

    static func export(_ archive: WorkoutArchive) throws -> Data { try exportWithStats(archive).data }

    static func exportWithStats(_ archive: WorkoutArchive) throws -> Result {
        guard archive.routes.contains(where: { !$0.points.isEmpty }) else { throw ExportError.noRoute }
        let validCount = archive.routes.reduce(0) { $0 + $1.points.filter(\.hasValidCoordinate).count }
        guard validCount > 0 else { throw ExportError.noValidPoint }
        let skipped = archive.totalRoutePointCount - validCount

        let workout = archive.workout
        let demoPrefix = archive.isDemoData ? "[DEMO – fictional data] " : ""
        let name = "\(demoPrefix)\(workout.activityType.name) \(ArchiveDateCoding.string(from: workout.startDate))"
        var desc = "Exported by WorkoutRescue from Apple Health (read-only). Workout UUID \(workout.uuid.uuidString). "
        desc += "Routes: \(archive.routes.count). Points written: \(validCount)."
        if skipped > 0 { desc += " Points skipped (invalid coordinate, kept in JSON): \(skipped)." }
        let incomplete = archive.routes.filter { !$0.isComplete }.count
        if incomplete > 0 { desc += " WARNING: \(incomplete) route(s) incomplete, see JSON." }

        var out = String()
        out.reserveCapacity(archive.totalRoutePointCount * 110 + 1024)
        out += "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        out += "<gpx version=\"1.1\" creator=\"WorkoutRescue\" xmlns=\"http://www.topografix.com/GPX/1/1\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xsi:schemaLocation=\"http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd\">\n"
        out += "<metadata>\n<name>\(escape(name))</name>\n<desc>\(escape(desc))</desc>\n<time>\(time(archive.exportedAt))</time>\n</metadata>\n"
        out += "<trk>\n<name>\(escape(name))</name>\n"
        if let source = workout.source.name { out += "<src>\(escape(source))</src>\n" }
        out += "<type>\(escape(workout.activityType.name))</type>\n"
        for route in archive.routes {
            let points = route.points.filter(\.hasValidCoordinate)
            guard !points.isEmpty else { continue }
            out += "<trkseg>\n"
            for point in points {
                out += "<trkpt lat=\"\(decimal(point.latitude))\" lon=\"\(decimal(point.longitude))\">"
                if point.hasValidAltitude { out += "<ele>\(decimal(point.altitude))</ele>" }
                out += "<time>\(time(point.timestamp))</time></trkpt>\n"
            }
            out += "</trkseg>\n"
        }
        out += "</trk>\n</gpx>\n"
        return Result(data: Data(out.utf8), writtenPointCount: validCount, skippedPointCount: skipped)
    }

    /// xsd:dateTime in UTC with millisecond precision (widely supported by GPX tools).
    static func time(_ date: Date) -> String {
        let full = ArchiveDateCoding.string(from: date) // ...SS.ffffffZ
        return String(full.dropLast(4)) + "Z"
    }

    /// xsd:decimal: shortest round-trip digits, never scientific notation.
    static func decimal(_ value: Double) -> String {
        let shortest = "\(value)"
        guard shortest.contains("e") || shortest.contains("E") else { return shortest }
        var fixed = String(format: "%.20f", value)
        while fixed.hasSuffix("0") { fixed.removeLast() }
        if fixed.hasSuffix(".") { fixed.removeLast() }
        return fixed
    }

    /// Escapes XML special characters and drops characters that are illegal in XML 1.0.
    static func escape(_ value: String) -> String {
        var result = String()
        result.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default:
                let v = scalar.value
                let legal = v == 0x9 || v == 0xA || v == 0xD || (0x20...0xD7FF).contains(v) || (0xE000...0xFFFD).contains(v) || (0x10000...0x10FFFF).contains(v)
                if legal { result.unicodeScalars.append(scalar) }
            }
        }
        return result
    }
}
