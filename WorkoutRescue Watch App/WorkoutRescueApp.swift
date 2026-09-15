//
//  WorkoutRescueApp.swift
//  WorkoutRescue Watch App
//
//  Created by Félix Chevalier on 16/09/2026.
//

import SwiftUI

@main
struct WorkoutRescue_Watch_AppApp: App {
    @State private var appState = AppState(repository: HealthKitService())

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
        }
    }
}
