import Foundation

enum AuthorizationPromptState: Equatable {
    case unavailable, notYetShown, alreadyShown, unknown
}

/// Source of workouts: HealthKit (real data) or the fictional demo set. Read-only by design:
/// there is intentionally no write, update or delete operation in this protocol.
protocol WorkoutRepository {
    var isDemo: Bool { get }
    func requestReadAuthorization() async throws
    func authorizationPromptState() async -> AuthorizationPromptState
    func fetchWorkouts() async throws -> [WorkoutSummary]
    func loadArchive(for id: UUID, progress: @escaping @Sendable (String) -> Void) async throws -> WorkoutArchive
}

/// Fictional workouts for Demo Mode (App Review, screenshots). Never touches HealthKit.
final class DemoWorkoutRepository: WorkoutRepository {
    var isDemo: Bool { true }
    func requestReadAuthorization() async throws {}
    func authorizationPromptState() async -> AuthorizationPromptState { .alreadyShown }
    func fetchWorkouts() async throws -> [WorkoutSummary] { DemoData.summaries }
    func loadArchive(for id: UUID, progress: @escaping @Sendable (String) -> Void) async throws -> WorkoutArchive {
        progress("Building fictional demo data…")
        guard var archive = DemoData.archive(for: id) else { throw HealthKitServiceError.workoutNotFound }
        archive.exportedAt = Date()
        return archive
    }
}
