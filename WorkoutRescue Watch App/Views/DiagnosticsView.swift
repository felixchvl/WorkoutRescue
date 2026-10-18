import SwiftUI

struct DiagnosticsView: View {
    @Environment(AppState.self) private var appState
    @State private var category: DiagnosticCategory?

    var body: some View {
        let entries = category.map { appState.diagnostics.entries(in: $0) } ?? appState.diagnostics.entries
        List {
            Picker("Filter", selection: $category) {
                Text("All").tag(DiagnosticCategory?.none)
                Text("HealthKit").tag(DiagnosticCategory?.some(.healthKit))
                Text("Export").tag(DiagnosticCategory?.some(.export))
                Text("Network").tag(DiagnosticCategory?.some(.network))
            }
            if entries.isEmpty { Text("No entries yet.").foregroundStyle(.secondary) }
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(entry.date.formatted(date: .omitted, time: .standard)) · \(entry.category.rawValue)")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(entry.message).font(.caption2)
                        .foregroundStyle(entry.level == .error ? .red : entry.level == .warning ? .orange : .primary)
                }
            }
        }
        .navigationTitle("Diagnostics")
    }
}
