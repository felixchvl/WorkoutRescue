import Foundation

/// What the user asked to send for one workout.
nonisolated enum ExportSelection: String, Codable, Sendable { case json, gpx, both }

/// Serialized files for one workout, built just before upload and released right after.
nonisolated struct ExportPayloads: Sendable {
    let json: Data
    let gpx: Data?
    /// Why no GPX was produced (no route, no valid coordinate), if any.
    let gpxUnavailableReason: String?
    let gpxPointCount: Int

    static func build(from archive: WorkoutArchive) throws -> ExportPayloads {
        let json = try JSONExporter.export(archive)
        do {
            let gpx = try GPXExporter.exportWithStats(archive)
            return ExportPayloads(json: json, gpx: gpx.data, gpxUnavailableReason: nil, gpxPointCount: gpx.writtenPointCount)
        } catch let error as GPXExporter.ExportError {
            return ExportPayloads(json: json, gpx: nil, gpxUnavailableReason: error.localizedDescription, gpxPointCount: 0)
        }
    }
}

/// Server-confirmed outcome for one workout. Persisted in `ExportLedger`.
nonisolated struct WorkoutExportResult: Codable, Equatable, Sendable {
    enum RouteStatus: String, Codable, Sendable { case uploaded, noRoute, notRequested }
    let workoutUUID: UUID
    let metadata: UploadReceipt?
    let route: UploadReceipt?
    let routeStatus: RouteStatus
    let jsonBytes: Int
    let gpxBytes: Int?
    let finishedAt: Date

    /// True when the JSON archive (source of truth) is confirmed and the GPX either confirmed or absent.
    var isComplete: Bool { metadata != nil && routeStatus != .notRequested }
}

nonisolated enum ExportStep: Sendable, Equatable {
    case serializing
    case uploading(UploadKind, attempt: Int, maxAttempts: Int)
}

/// Serializes and uploads one workout. JSON first (it is the archive), then GPX.
/// Never reports success without the server confirmation of every requested file.
nonisolated struct WorkoutUploadPipeline: Sendable {
    let uploader: RecoveryUploader

    func export(_ archive: WorkoutArchive, selection: ExportSelection,
                onStep: (@Sendable (ExportStep) -> Void)? = nil) async throws -> WorkoutExportResult {
        onStep?(.serializing)
        let payloads = try ExportPayloads.build(from: archive)
        let uuid = archive.workout.uuid
        var metadataReceipt: UploadReceipt?
        var routeReceipt: UploadReceipt?
        var routeStatus = WorkoutExportResult.RouteStatus.notRequested

        if selection != .gpx {
            metadataReceipt = try await uploader.upload(payloads.json, kind: .metadata, workoutUUID: uuid) { p in
                onStep?(.uploading(.metadata, attempt: p.attempt, maxAttempts: p.maxAttempts))
            }
        }
        if selection != .json {
            if let gpx = payloads.gpx {
                routeReceipt = try await uploader.upload(gpx, kind: .route, workoutUUID: uuid) { p in
                    onStep?(.uploading(.route, attempt: p.attempt, maxAttempts: p.maxAttempts))
                }
                routeStatus = .uploaded
            } else if selection == .gpx {
                throw GPXExporter.ExportError.noRoute
            } else {
                routeStatus = .noRoute
            }
        }
        return WorkoutExportResult(workoutUUID: uuid, metadata: metadataReceipt, route: routeReceipt, routeStatus: routeStatus,
                                   jsonBytes: payloads.json.count, gpxBytes: payloads.gpx?.count, finishedAt: Date())
    }
}

/// Local record of server-confirmed exports, used by "Export All" to avoid unintended duplicates.
/// Contains only workout UUIDs, digests and dates — no health values.
final class ExportLedger {
    private let defaults: UserDefaults
    private let key: String
    private(set) var results: [UUID: WorkoutExportResult] = [:]

    init(defaults: UserDefaults = .standard, key: String = "exportLedger.v1") {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key),
           let stored = try? JSONExporter.makeDecoder().decode([UUID: WorkoutExportResult].self, from: data) {
            results = stored
        }
    }

    func result(for uuid: UUID) -> WorkoutExportResult? { results[uuid] }
    func isComplete(_ uuid: UUID) -> Bool { results[uuid]?.isComplete ?? false }
    var lastResult: WorkoutExportResult? { results.values.max { $0.finishedAt < $1.finishedAt } }

    /// Merges a new confirmation with an earlier one (e.g. JSON now, GPX later).
    func record(_ result: WorkoutExportResult) {
        let previous = results[result.workoutUUID]
        let merged = WorkoutExportResult(
            workoutUUID: result.workoutUUID,
            metadata: result.metadata ?? previous?.metadata,
            route: result.route ?? previous?.route,
            routeStatus: result.routeStatus == .notRequested ? (previous?.routeStatus ?? .notRequested) : result.routeStatus,
            jsonBytes: result.metadata != nil ? result.jsonBytes : (previous?.jsonBytes ?? result.jsonBytes),
            gpxBytes: result.gpxBytes ?? previous?.gpxBytes,
            finishedAt: result.finishedAt)
        results[result.workoutUUID] = merged
        if let data = try? JSONExporter.makeEncoder().encode(results) { defaults.set(data, forKey: key) }
    }
}
