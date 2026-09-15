//
//  ContentView.swift
//  WorkoutRescue Watch App
//
//  Created by Félix Chevalier on 16/09/2026.
//

import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        TabView {
            StatusView()
            WorkoutsView()
            SettingsView()
        }
        .tabViewStyle(.verticalPage)
    }
}
