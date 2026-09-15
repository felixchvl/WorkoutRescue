import Foundation

@MainActor
protocol WorkoutRepository {
    func requestReadAuthorization() async throws
    func fetchWorkouts() async throws -> [WorkoutSummary]
}

@MainActor
final class MockWorkoutRepository: WorkoutRepository {
    func requestReadAuthorization() async throws {}
    func fetchWorkouts() async throws -> [WorkoutSummary] {
        [WorkoutSummary(id: UUID(uuidString: "9D0CCF8D-6A76-4DE3-9D8C-987AA1D4E2AE")!, activityTypeRawValue: 1, startDate: .now.addingTimeInterval(-3_600), endDate: .now, duration: 3_600, totalDistanceMeters: 9_800, totalActiveEnergyKilocalories: 680, sourceName: "Simulator sample")]
    }
}
