import Foundation

/// This small ledger is independent of checkpoint writes from the training queue.
/// Old sessions without this ledger remain available for explicit recovery.
struct GaussianRunIntention: Codable, Equatable, Sendable {
    enum Intent: String, Codable, Sendable { case running, manuallyPaused, stopped, completed, failed }
    var schemaVersion = 1
    var intent: Intent
    var exportRequested: Bool
    var updatedAt: Date

    func shouldRecover(sessionState: String) -> Bool {
        intent == .running && sessionState != "exported"
    }

    static func load(from workspace: URL) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: workspace.appendingPathComponent("run-intention.json")))
        guard value.schemaVersion == 1 else { throw CocoaError(.coderReadCorrupt) }
        return value
    }

    static func save(_ intent: Intent, exportRequested: Bool, to workspace: URL) throws {
        let value = Self(intent: intent, exportRequested: exportRequested, updatedAt: Date())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: workspace.appendingPathComponent("run-intention.json"), options: .atomic)
    }
}
