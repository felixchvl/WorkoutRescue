import Foundation

enum DiagnosticLevel: String, Codable, Sendable { case info, warning, error }

struct DiagnosticEntry: Identifiable, Codable, Sendable {
    let id: UUID
    let date: Date
    let level: DiagnosticLevel
    let message: String

    init(level: DiagnosticLevel, message: String, date: Date = .now) {
        self.id = UUID(); self.date = date; self.level = level; self.message = message
    }
}

/// Keeps operational diagnostics local to the app. Never put Health data in system logs.
@MainActor
final class DiagnosticLog {
    private(set) var entries: [DiagnosticEntry] = []

    func add(_ level: DiagnosticLevel = .info, _ message: String) {
        entries.insert(DiagnosticEntry(level: level, message: message), at: 0)
        if entries.count > 200 { entries.removeLast(entries.count - 200) }
    }
}
