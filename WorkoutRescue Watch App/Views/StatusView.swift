import SwiftUI

struct StatusView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label("Workout Rescue", systemImage: "cross.case")
                    .font(.headline)
                LabeledContent("Health Access", value: appState.healthAccessState.label)
                LabeledContent("Workouts", value: "\(appState.workouts.count)")
                if let lastScan = appState.lastScan {
                    LabeledContent("Last Scan", value: lastScan.formatted(date: .abbreviated, time: .shortened))
                }
                Button("Authorize Health Access") { Task { await appState.authorizeAndScan() } }
                    .disabled(appState.healthAccessState == .requesting)
                Button("Scan Workouts") { Task { await appState.scan() } }
                    .disabled(appState.isScanning)
                if let latest = appState.diagnostics.entries.first {
                    Text(latest.message).font(.footnote).foregroundStyle(latest.level == .error ? .red : .secondary)
                }
            }
            .padding()
        }
        .navigationTitle("Status")
    }
}
