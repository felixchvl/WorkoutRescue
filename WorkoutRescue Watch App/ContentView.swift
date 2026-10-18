//
//  ContentView.swift
//  WorkoutRescue Watch App
//
//  Created by Félix Chevalier on 16/09/2026.
//

import SwiftUI

/// Dashboard: status at a glance, then navigation to the other screens.
struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var path = NavigationPath()

    enum Screen: Hashable { case workouts, exportAll, settings, diagnostics }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if appState.demoMode {
                    Label("DEMO MODE – fictional data, not from Apple Health", systemImage: "theatermasks")
                        .font(.footnote).foregroundStyle(.orange)
                }
                Section {
                    LabeledContent("Workouts", value: appState.lastScan == nil ? "—" : "\(appState.workouts.count)")
                    LabeledContent("Last scan", value: appState.lastScan?.formatted(date: .omitted, time: .shortened) ?? "Never")
                    LabeledContent("Receiver", value: appState.connection.label)
                    LabeledContent("Last export", value: appState.lastExport?.finishedAt.formatted(date: .abbreviated, time: .shortened) ?? "None")
                }
                .font(.footnote)

                if !appState.demoMode, appState.promptState != .alreadyShown {
                    Button { Task { await appState.authorizeAndScan() } } label: {
                        Label("Allow Health Access", systemImage: "heart.text.square")
                    }
                } else {
                    Button { Task { await appState.scan() } } label: {
                        Label(appState.isScanning ? "Scanning…" : "Scan Workouts", systemImage: "arrow.clockwise")
                    }
                    .disabled(appState.isScanning)
                }
                if let error = appState.scanError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                } else if appState.lastScan != nil, appState.workouts.isEmpty, !appState.demoMode {
                    Text("No workout readable. HealthKit does not say whether read access was denied: check Health access for WorkoutRescue in the Settings app, then scan again.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                NavigationLink(value: Screen.workouts) { Label("Workouts", systemImage: "figure.outdoor.cycle") }
                NavigationLink(value: Screen.exportAll) { Label("Export All", systemImage: "square.and.arrow.up.on.square") }
                NavigationLink(value: Screen.settings) { Label("Settings", systemImage: "gear") }
                NavigationLink(value: Screen.diagnostics) { Label("Diagnostics", systemImage: "stethoscope") }
            }
            .navigationTitle("WorkoutRescue")
            .navigationDestination(for: Screen.self) { screen in
                switch screen {
                case .workouts: WorkoutsView()
                case .exportAll: ExportAllView()
                case .settings: SettingsView()
                case .diagnostics: DiagnosticsView()
                }
            }
            .navigationDestination(for: WorkoutSummary.self) { WorkoutDetailView(summary: $0) }
        }
        .task {
            await appState.refreshPromptState()
            #if DEBUG
            await openScreenForUITesting()
            #endif
        }
    }
}

#if DEBUG
extension ContentView {
    /// Debug builds only: `WR_SCREEN=workouts|detail|exportAll|settings|diagnostics` opens a screen at launch
    /// so the simulator smoke test can capture every screen without taps. Not compiled into Release.
    private func openScreenForUITesting() async {
        guard let screen = ProcessInfo.processInfo.environment["WR_SCREEN"] else { return }
        switch screen {
        case "workouts": path.append(Screen.workouts)
        case "detail":
            await appState.scan()
            path.append(Screen.workouts)
            if let ride = appState.workouts.first(where: { $0.activityTypeRawValue == ActivityTypeNames.cycling }) ?? appState.workouts.first { path.append(ride) }
        case "exportAll":
            await appState.scan()
            path.append(Screen.exportAll)
        case "settings": path.append(Screen.settings)
        case "diagnostics": path.append(Screen.diagnostics)
        default: break
        }
    }
}
#endif
