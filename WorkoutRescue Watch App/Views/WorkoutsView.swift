import SwiftUI

struct WorkoutsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        List(appState.workouts) { workout in
            NavigationLink(value: workout) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(workout.activityDisplayName).font(.headline)
                    Text(workout.startDate.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                    Text([workout.durationText, workout.distanceText].compactMap { $0 }.joined(separator: " · ")).font(.caption2)
                }
            }
        }
        .overlay {
            if appState.workouts.isEmpty {
                ContentUnavailableView("No Workouts", systemImage: "figure.run", description: Text("Authorize Health access, then scan this Apple Watch."))
            }
        }
        .navigationDestination(for: WorkoutSummary.self) { WorkoutDetailView(workout: $0) }
        .navigationTitle("Workouts")
        .task { await appState.scan() }
    }
}

private struct WorkoutDetailView: View {
    let workout: WorkoutSummary
    var body: some View {
        List {
            LabeledContent("UUID", value: workout.id.uuidString)
            LabeledContent("Activity", value: workout.activityDisplayName)
            LabeledContent("Start", value: workout.startDate.formatted(date: .abbreviated, time: .shortened))
            LabeledContent("End", value: workout.endDate.formatted(date: .abbreviated, time: .shortened))
            LabeledContent("Duration", value: workout.durationText)
            if let distance = workout.distanceText { LabeledContent("Distance", value: distance) }
            if let energy = workout.totalActiveEnergyKilocalories { LabeledContent("Active Energy", value: "\(energy.formatted()) kcal") }
            if let source = workout.sourceName { LabeledContent("Source", value: source) }
        }.navigationTitle("Workout")
    }
}
