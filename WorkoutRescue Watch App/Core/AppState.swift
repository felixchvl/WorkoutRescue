import Foundation
import Observation

@Observable
final class AppState {
    enum ConnectionStatus: Equatable {
        case notConfigured, untested, testing, ok(Date), failed(String)
        var label: String {
            switch self {
            case .notConfigured: return "Not configured"
            case .untested: return "Not tested"
            case .testing: return "Testing…"
            case .ok(let date): return "OK \(date.formatted(date: .omitted, time: .shortened))"
            case .failed: return "Failed"
            }
        }
    }

    struct BatchState: Equatable {
        var isRunning = false
        var total = 0
        var done = 0
        var succeeded = 0
        var skipped = 0
        var failed = 0
        var current: String?
        var lines: [String] = []
    }

    let diagnostics = DiagnosticLog()
    let ledger = ExportLedger()
    private let healthRepository: any WorkoutRepository
    private let demoRepository: any WorkoutRepository = DemoWorkoutRepository()

    var demoMode: Bool { didSet { UserDefaults.standard.set(demoMode, forKey: "demoMode"); workouts = []; lastScan = nil } }
    var repository: any WorkoutRepository { demoMode ? demoRepository : healthRepository }

    var promptState: AuthorizationPromptState = .unknown
    var workouts: [WorkoutSummary] = []
    var lastScan: Date?
    var isScanning = false
    var scanError: String?

    var endpointText: String { didSet { UserDefaults.standard.set(endpointText, forKey: "endpoint"); connection = endpointText.isEmpty ? .notConfigured : .untested } }
    private(set) var hasToken: Bool
    private var sessionToken: String?
    var connection: ConnectionStatus
    var batch = BatchState()
    private var batchTask: Task<Void, Never>?

    init(healthRepository: any WorkoutRepository) {
        self.healthRepository = healthRepository
        self.demoMode = UserDefaults.standard.bool(forKey: "demoMode")
        let endpoint = UserDefaults.standard.string(forKey: "endpoint") ?? ""
        self.endpointText = endpoint
        let token = KeychainStore.readToken()
        self.sessionToken = token
        self.hasToken = !(token ?? "").isEmpty
        self.connection = endpoint.isEmpty ? .notConfigured : .untested
    }

    var lastExport: WorkoutExportResult? { ledger.lastResult }

    // MARK: HealthKit

    func refreshPromptState() async { promptState = await repository.authorizationPromptState() }

    func authorizeAndScan() async {
        diagnostics.add(.info, .healthKit, "Requesting read-only HealthKit access.")
        do {
            try await repository.requestReadAuthorization()
            diagnostics.add(.info, .healthKit, "Authorization request completed (HealthKit does not reveal which read types were allowed).")
        } catch {
            diagnostics.add(.error, .healthKit, "Authorization failed: \(error.localizedDescription)")
        }
        await refreshPromptState()
        await scan()
    }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        do {
            workouts = try await repository.fetchWorkouts()
            lastScan = .now
            scanError = nil
            diagnostics.add(.info, .healthKit, "Scan: \(workouts.count) readable workout(s)\(demoMode ? " (DEMO data)" : "").")
        } catch {
            scanError = error.localizedDescription
            diagnostics.add(.error, .healthKit, "Workout query failed: \(error.localizedDescription)")
        }
    }

    func loadArchive(for id: UUID, progress: @escaping @Sendable (String) -> Void) async throws -> WorkoutArchive {
        do {
            let archive = try await repository.loadArchive(for: id, progress: progress)
            diagnostics.add(.info, .healthKit, "Read \(id.uuidString.prefix(8)): \(archive.totalRoutePointCount) GPS points, \(archive.routes.count) route(s), \(archive.quantityTypes.reduce(0) { $0 + $1.samples.count }) samples.")
            for warning in archive.warnings { diagnostics.add(.warning, .healthKit, "\(id.uuidString.prefix(8)): \(warning)") }
            return archive
        } catch {
            diagnostics.add(.error, .healthKit, "Read \(id.uuidString.prefix(8)) failed: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: Receiver settings

    func saveSettings(endpoint: String, token: String?) throws {
        let parsed = try RecoveryEndpoint.parse(endpoint)
        endpointText = parsed.baseURL.absoluteString
        if let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
            sessionToken = clean
            hasToken = true
            do { try KeychainStore.saveToken(clean) } catch {
                diagnostics.add(.warning, .network, "Token kept for this session only: \(error.localizedDescription)")
            }
        }
        diagnostics.add(.info, .network, "Receiver set to \(parsed.baseURL.host() ?? "?").")
    }

    func forgetToken() {
        KeychainStore.deleteToken()
        sessionToken = nil
        hasToken = false
        connection = endpointText.isEmpty ? .notConfigured : .untested
    }

    func makeUploader() throws -> RecoveryUploader {
        guard let token = sessionToken, !token.isEmpty else { throw SettingsError.missingToken }
        return RecoveryUploader(endpoint: try RecoveryEndpoint.parse(endpointText), token: token)
    }

    enum SettingsError: LocalizedError {
        case missingToken
        var errorDescription: String? { "Enter the receiver token in Settings." }
    }

    func testConnection() async {
        connection = .testing
        do {
            let result = try await makeUploader().ping()
            connection = .ok(.now)
            diagnostics.add(.info, .network, "Connection OK (\(result.service ?? "receiver"), protocol \(result.protocolVersion ?? 0)).")
        } catch {
            connection = .failed(error.localizedDescription)
            diagnostics.add(.error, .network, "Connection test failed: \(error.localizedDescription)")
        }
    }

    // MARK: Export

    /// Uploads an already-read archive. Health data leaves the watch only from here, after an explicit tap.
    func export(_ archive: WorkoutArchive, selection: ExportSelection, onStep: @escaping @Sendable (ExportStep) -> Void) async throws -> WorkoutExportResult {
        let short = archive.workout.uuid.uuidString.prefix(8)
        do {
            let pipeline = WorkoutUploadPipeline(uploader: try makeUploader())
            let result = try await pipeline.export(archive, selection: selection, onStep: onStep)
            ledger.record(result)
            let parts = [result.metadata.map { "JSON \($0.status) \($0.bytes) B sha \($0.sha256.prefix(8))" },
                         result.route.map { "GPX \($0.status) \($0.bytes) B sha \($0.sha256.prefix(8))" },
                         result.routeStatus == .noRoute ? "no GPS route" : nil].compactMap { $0 }
            diagnostics.add(.info, .export, "\(short): server confirmed — \(parts.joined(separator: ", ")).")
            return result
        } catch {
            diagnostics.add(.error, .export, "\(short): export failed — \(error.localizedDescription)")
            throw error
        }
    }

    /// Sequential "Export All": read one workout, upload it, release it, then the next one.
    func startExportAll(skipAlreadyExported: Bool) {
        guard !batch.isRunning else { return }
        let targets = workouts
        batch = BatchState(isRunning: true, total: targets.count)
        diagnostics.add(.info, .export, "Export All started: \(targets.count) workout(s).")
        batchTask = Task { [weak self] in
            for summary in targets {
                guard let self, !Task.isCancelled else { break }
                let label = "\(summary.activityDisplayName) \(summary.startDate.formatted(date: .abbreviated, time: .omitted))"
                self.batch.current = label
                if skipAlreadyExported, self.ledger.isComplete(summary.id) {
                    self.batch.skipped += 1
                    self.batch.lines.insert("⏭ \(label): already confirmed", at: 0)
                } else {
                    do {
                        let archive = try await self.loadArchive(for: summary.id) { _ in }
                        let result = try await self.export(archive, selection: .both) { _ in }
                        self.batch.succeeded += 1
                        self.batch.lines.insert("✅ \(label)\(result.routeStatus == .noRoute ? " (no GPS)" : "")", at: 0)
                    } catch {
                        self.batch.failed += 1
                        self.batch.lines.insert("❌ \(label): \(error.localizedDescription)", at: 0)
                        if case UploadError.unauthorized = error { self.batch.lines.insert("Stopped: token refused.", at: 0); break }
                    }
                }
                self.batch.done += 1
            }
            guard let self else { return }
            self.batch.isRunning = false
            self.batch.current = nil
            self.diagnostics.add(.info, .export, "Export All finished: \(self.batch.succeeded) confirmed, \(self.batch.skipped) skipped, \(self.batch.failed) failed.")
        }
    }

    func cancelExportAll() {
        batchTask?.cancel()
        diagnostics.add(.warning, .export, "Export All cancelled by user.")
    }
}
