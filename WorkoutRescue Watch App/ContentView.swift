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

    var body: some View {
        NavigationStack {
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

                NavigationLink { WorkoutsView() } label: { Label("Workouts", systemImage: "figure.outdoor.cycle") }
                NavigationLink { ExportAllView() } label: { Label("Export All", systemImage: "square.and.arrow.up.on.square") }
                NavigationLink { SettingsView() } label: { Label("Settings", systemImage: "gear") }
                NavigationLink { DiagnosticsView() } label: { Label("Diagnostics", systemImage: "stethoscope") }
            }
            .navigationTitle("WorkoutRescue")
        }
        .task { await appState.refreshPromptState() }
    }
}
