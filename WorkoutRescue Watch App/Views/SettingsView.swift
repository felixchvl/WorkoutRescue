import SwiftUI

struct SettingsView: View {
    var body: some View {
        List {
            Section("Recovery Safety") {
                Label("Read-only HealthKit", systemImage: "lock.shield")
                Text("Workout Rescue never deletes, edits, or writes HealthKit workouts.").font(.footnote)
            }
            Section("Export") {
                Text("Endpoint configuration and upload controls are added after the archival exporters are validated.").font(.footnote)
            }
        }.navigationTitle("Settings")
    }
}
