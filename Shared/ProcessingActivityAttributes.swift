import ActivityKit
import AppIntents
import Foundation

/// The same value types are compiled into the application and its Live Activity extension.
struct FormaProcessingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        var progress: Double
        var status: String
        var phase: String
        var energyLabel: String
    }

    let jobID: UUID
    let title: String
}

/// LiveActivityIntent executes in the host application's process, where the active
/// processing controller receives this notification. No shared container is needed.
struct FormaProcessingActionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Controlar procesamiento de Forma"
    static var description = IntentDescription("Pausa o reanuda el trabajo local que aparece en la actividad de Forma.")
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Trabajo") var jobID: String
    @Parameter(title: "Acción") var action: String

    init() {}

    init(jobID: String, action: String) {
        self.jobID = jobID
        self.action = action
    }

    func perform() async throws -> some IntentResult {
        let requestedID = jobID
        let requestedAction = action
        guard UUID(uuidString: requestedID) != nil,
              requestedAction == "pause" || requestedAction == "resume" else {
            return .result()
        }
        await MainActor.run {
            NotificationCenter.default.post(
                name: Notification.Name("FormaProcessingActivityAction"),
                object: nil,
                userInfo: ["jobID": requestedID, "action": requestedAction])
        }
        return .result()
    }
}
