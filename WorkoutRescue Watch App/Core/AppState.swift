import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    enum HealthAccessState: Equatable {
        case notRequested, requesting, requested, failed(String)
        var label: String {
            switch self {
            case .notRequested: return "Not Authorized"
            case .requesting: return "Requesting…"
            case .requested: return "Access Requested"
            case .failed: return "Authorization Error"
            }
        }
    }

    private let repository: any WorkoutRepository
    let diagnostics = DiagnosticLog()
    var healthAccessState: HealthAccessState = .notRequested
    var workouts: [WorkoutSummary] = []
    var lastScan: Date?
    var isScanning = false

    init(repository: any WorkoutRepository) { self.repository = repository }

    func authorizeAndScan() async {
        healthAccessState = .requesting
        diagnostics.add(.info, "Requesting read-only HealthKit access.")
        do {
            try await repository.requestReadAuthorization()
            healthAccessState = .requested
            diagnostics.add(.info, "HealthKit authorization request completed.")
            await scan()
        } catch {
            healthAccessState = .failed(error.localizedDescription)
            diagnostics.add(.error, "HealthKit authorization failed: \(error.localizedDescription)")
        }
    }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        do {
            workouts = try await repository.fetchWorkouts()
            lastScan = .now
            diagnostics.add(.info, "Found \(workouts.count) accessible workout(s).")
        } catch {
            diagnostics.add(.error, "Workout query failed: \(error.localizedDescription)")
        }
    }
}
