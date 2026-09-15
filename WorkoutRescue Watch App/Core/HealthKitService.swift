import Foundation
import HealthKit

/// Read-only HealthKit access. This type never calls save, delete, or workout-session APIs.
@MainActor
final class HealthKitService: WorkoutRepository {
    private let healthStore: HKHealthStore

    init(healthStore: HKHealthStore = HKHealthStore()) { self.healthStore = healthStore }

    private var readTypes: Set<HKObjectType> {
        [
            HKObjectType.workoutType(), HKSeriesType.workoutRoute(), HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned), HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.distanceCycling), HKQuantityType(.runningSpeed),
            HKQuantityType(.runningPower), HKQuantityType(.runningStrideLength),
            HKQuantityType(.runningVerticalOscillation), HKQuantityType(.runningGroundContactTime),
            HKQuantityType(.cyclingSpeed), HKQuantityType(.cyclingCadence)
        ]
    }

    func requestReadAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthKitServiceError.healthDataUnavailable }
        try await healthStore.requestAuthorization(toShare: [], read: readTypes)
    }

    func fetchWorkouts() async throws -> [WorkoutSummary] {
        try await withCheckedThrowingContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            let query = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: nil, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                let workouts = (samples as? [HKWorkout] ?? []).map { workout in
                    let energyType = HKQuantityType(.activeEnergyBurned)
                    let energy = workout.statistics(for: energyType)?.sumQuantity()?.doubleValue(for: .kilocalorie())
                    return WorkoutSummary(id: workout.uuid, activityTypeRawValue: workout.workoutActivityType.rawValue, startDate: workout.startDate, endDate: workout.endDate, duration: workout.duration, totalDistanceMeters: workout.totalDistance?.doubleValue(for: .meter()), totalActiveEnergyKilocalories: energy, sourceName: workout.sourceRevision.source.name)
                }
                continuation.resume(returning: workouts)
            }
            healthStore.execute(query)
        }
    }
}

enum HealthKitServiceError: LocalizedError {
    case healthDataUnavailable
    var errorDescription: String? { "HealthKit is unavailable on this Apple Watch." }
}
