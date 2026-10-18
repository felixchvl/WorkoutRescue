import SwiftUI

struct WorkoutsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        List(appState.workouts) { workout in
            NavigationLink(value: workout) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(workout.activityDisplayName).font(.headline).lineLimit(1)
                        if appState.ledger.isComplete(workout.id) { Image(systemName: "checkmark.icloud").foregroundStyle(.green) }
                    }
                    Text(workout.startDate.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                    Text([workout.durationText, workout.distanceText].compactMap { $0 }.joined(separator: " · ")).font(.caption2)
                    if workout.isDemoData { Text("DEMO – fictional").font(.caption2).foregroundStyle(.orange) }
                }
            }
        }
        .overlay {
            if appState.workouts.isEmpty {
                ContentUnavailableView(appState.isScanning ? "Scanning…" : "No Workouts", systemImage: "figure.run",
                                       description: Text("Allow Health access on the main screen, then scan this Apple Watch."))
            }
        }
        .navigationTitle("Workouts")
        .task { if appState.lastScan == nil { await appState.scan() } }
    }
}

/// Reads the full workout (route + samples) only when opened; the data is released when leaving.
struct WorkoutDetailView: View {
    @Environment(AppState.self) private var appState
    let summary: WorkoutSummary
    @State private var archive: WorkoutArchive?
    @State private var loadError: String?
    @State private var loadStatus = "Reading…"
    @State private var exportStatus: String?
    @State private var exportError: String?
    @State private var isExporting = false

    var body: some View {
        List {
            // Most important first on a small screen: what was read, then the export actions.
            Section {
                if summary.isDemoData { Text("DEMO – fictional data").foregroundStyle(.orange) }
                Text(summary.startDate.formatted(date: .abbreviated, time: .shortened))
                Text([summary.durationText, summary.distanceText].compactMap { $0 }.joined(separator: " · "))
            }
            .font(.footnote)
            Section("Data read") {
                if let archive {
                    LabeledContent("GPS points", value: "\(archive.totalRoutePointCount)")
                    LabeledContent("Heart rate", value: "\(archive.sampleCount(for: "HKQuantityTypeIdentifierHeartRate"))")
                    LabeledContent("All samples", value: "\(archive.quantityTypes.reduce(0) { $0 + $1.samples.count })")
                    LabeledContent("Routes", value: "\(archive.routes.count)")
                    if archive.routes.contains(where: { !$0.isComplete }) {
                        Text("⚠️ A route looks incomplete — see Diagnostics.").foregroundStyle(.orange)
                    }
                    ForEach(archive.warnings, id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
                } else if let loadError {
                    Text(loadError).foregroundStyle(.red)
                    Button("Retry") { Task { await load() } }
                } else {
                    HStack { ProgressView(); Text(loadStatus).font(.caption2) }
                }
            }
            .font(.footnote)
            if let archive {
                Section("Export") {
                    Button("Export Workout") { Task { await export(archive, .both) } }.disabled(isExporting)
                    Button("Export JSON") { Task { await export(archive, .json) } }.disabled(isExporting)
                    Button("Export GPX") { Task { await export(archive, .gpx) } }.disabled(isExporting || archive.totalRoutePointCount == 0)
                    if let exportStatus { Text(exportStatus).font(.caption2).foregroundStyle(.green) }
                    if let exportError { Text(exportError).font(.caption2).foregroundStyle(.red) }
                    if isExporting { Text("Keep the screen on until the receiver confirms.").font(.caption2).foregroundStyle(.secondary) }
                }
            }
            Section("Details") {
                LabeledContent("Activity", value: summary.activityDisplayName)
                LabeledContent("End", value: summary.endDate.formatted(date: .omitted, time: .shortened))
                if let energy = summary.totalActiveEnergyKilocalories { LabeledContent("Active energy", value: "\(Int(energy.rounded())) kcal") }
                if let source = summary.sourceName { LabeledContent("Source", value: source) }
                Text(summary.id.uuidString).font(.caption2).foregroundStyle(.secondary)
            }
            .font(.footnote)
        }
        .navigationTitle(summary.activityDisplayName)
        .task { await load() }
    }

    private func load() async {
        loadError = nil
        do {
            archive = try await appState.loadArchive(for: summary.id) { status in Task { @MainActor in loadStatus = status } }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func export(_ archive: WorkoutArchive, _ selection: ExportSelection) async {
        isExporting = true
        exportError = nil
        exportStatus = "Preparing…"
        defer { isExporting = false }
        do {
            let result = try await appState.export(archive, selection: selection) { step in
                Task { @MainActor in
                    switch step {
                    case .serializing: exportStatus = "Serializing…"
                    case .uploading(let kind, let attempt, let max): exportStatus = "Sending \(kind.fileName) (try \(attempt)/\(max))…"
                    }
                }
            }
            var lines: [String] = []
            if let m = result.metadata { lines.append("JSON confirmed (\(m.status))") }
            if let r = result.route { lines.append("GPX confirmed (\(r.status))") }
            if result.routeStatus == .noRoute { lines.append("No GPS route to send") }
            exportStatus = "✅ " + lines.joined(separator: " · ")
        } catch {
            exportStatus = nil
            exportError = error.localizedDescription
        }
    }
}
