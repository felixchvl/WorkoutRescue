import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var endpoint = ""
    @State private var token = ""
    @State private var message: String?
    @State private var isError = false

    var body: some View {
        @Bindable var state = appState
        List {
            Section("Receiver (HTTPS)") {
                TextField("rescue.example.org", text: $endpoint)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField(appState.hasToken ? "Token saved – type to replace" : "Token", text: $token)
                Button("Save") { save() }
                Button("Test Connection") { Task { save(); await appState.testConnection() } }
                    .disabled(endpoint.isEmpty || (!appState.hasToken && token.isEmpty))
                LabeledContent("Status", value: appState.connection.label).font(.footnote)
                if case .failed(let reason) = appState.connection { Text(reason).font(.caption2).foregroundStyle(.red) }
                if let message { Text(message).font(.caption2).foregroundStyle(isError ? .red : .green) }
                if appState.hasToken { Button("Forget Token", role: .destructive) { appState.forgetToken(); token = "" } }
            }
            Section("Demo") {
                Toggle("Demo mode", isOn: $state.demoMode)
                Text("Shows fictional workouts clearly marked DEMO. They never come from or go to Apple Health.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section("Safety") {
                Label("Read-only Apple Health access", systemImage: "lock.shield")
                Text("WorkoutRescue never writes, edits or deletes Health data. Data leaves the watch only when you tap an export button, and only to the receiver above.")
                    .font(.caption2)
            }
        }
        .navigationTitle("Settings")
        .onAppear { endpoint = appState.endpointText }
    }

    private func save() {
        do {
            try appState.saveSettings(endpoint: endpoint, token: token.isEmpty ? nil : token)
            endpoint = appState.endpointText
            token = ""
            message = "Saved"
            isError = false
        } catch {
            message = error.localizedDescription
            isError = true
        }
    }
}
