import Foundation
import Observation

enum DiagnosticLevel: String, Codable, Sendable { case info, warning, error }
enum DiagnosticCategory: String, Codable, Sendable { case healthKit = "HealthKit", export = "Export", network = "Network", app = "App" }

struct DiagnosticEntry: Identifiable, Codable, Sendable {
    let id: UUID
    let date: Date
    let level: DiagnosticLevel
    let category: DiagnosticCategory
    let message: String

    init(level: DiagnosticLevel, category: DiagnosticCategory, message: String, date: Date = .now) {
        self.id = UUID(); self.date = date; self.level = level; self.category = category; self.message = message
    }
}

/// In-app operational log. Holds counts, UUIDs, statuses and errors only — never health values —
/// and is never written to the system log or sent anywhere.
@Observable
final class DiagnosticLog {
    private(set) var entries: [DiagnosticEntry] = []

    func add(_ level: DiagnosticLevel = .info, _ category: DiagnosticCategory = .app, _ message: String) {
        entries.insert(DiagnosticEntry(level: level, category: category, message: message), at: 0)
        if entries.count > 300 { entries.removeLast(entries.count - 300) }
    }

    func entries(in category: DiagnosticCategory) -> [DiagnosticEntry] { entries.filter { $0.category == category } }
}
