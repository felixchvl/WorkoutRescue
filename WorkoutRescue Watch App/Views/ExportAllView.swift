import SwiftUI

struct ExportAllView: View {
    @Environment(AppState.self) private var appState
    @State private var skipAlreadyExported = true

    var body: some View {
        let batch = appState.batch
        List {
            Section {
                LabeledContent("Workouts", value: "\(appState.workouts.count)")
                LabeledContent("Already confirmed", value: "\(appState.workouts.filter { appState.ledger.isComplete($0.id) }.count)")
                Toggle("Skip confirmed", isOn: $skipAlreadyExported).disabled(batch.isRunning)
            }
            .font(.footnote)
            if batch.isRunning {
                Section {
                    ProgressView(value: Double(batch.done), total: Double(max(batch.total, 1)))
                    Text("\(batch.done)/\(batch.total) \(batch.current ?? "")").font(.caption2)
                    Text("Keep the screen on. Each workout counts only once the receiver confirms its SHA-256.").font(.caption2).foregroundStyle(.secondary)
                    Button("Stop", role: .destructive) { appState.cancelExportAll() }
                }
            } else {
                Button {
                    appState.startExportAll(skipAlreadyExported: skipAlreadyExported)
                } label: { Label("Send All to Receiver", systemImage: "square.and.arrow.up") }
                .disabled(appState.workouts.isEmpty)
                if appState.workouts.isEmpty { Text("Scan workouts first.").font(.footnote).foregroundStyle(.secondary) }
            }
            if batch.total > 0 {
                Section("Result") {
                    Text("✅ \(batch.succeeded)  ⏭ \(batch.skipped)  ❌ \(batch.failed)").font(.footnote)
                    ForEach(Array(batch.lines.prefix(50).enumerated()), id: \.offset) { Text($0.element).font(.caption2) }
                }
            }
        }
        .navigationTitle("Export All")
    }
}
