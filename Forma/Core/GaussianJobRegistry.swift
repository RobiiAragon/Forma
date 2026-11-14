import Combine
import UIKit

/// Jobs belong to the application, rather than the lifetime of a presentation.
@MainActor
final class GaussianJobRegistry {
    static let shared = GaussianJobRegistry()
    private var trainers: [GaussianTrainerService] = []
    private var recovered = false

    func trainer(datasetURL: URL) -> GaussianTrainerService {
        let path = datasetURL.standardizedFileURL.path
        if let existing = trainers.reversed().first(where: {
            $0.datasetPath == path && ($0.phase != .ready ||
                $0.result.map { FileManager.default.fileExists(atPath: $0.modelURL?.path ?? "") } == true)
        }) { return existing }
        let trainer = GaussianTrainerService()
        trainer.datasetPath = path
        trainers.append(trainer)
        return trainer
    }

    func trainer(session: GaussianRecoverySession) -> GaussianTrainerService {
        if let existing = trainers.first(where: { $0.sessionID == session.id }) { return existing }
        let trainer = GaussianTrainerService(session: session)
        trainers.append(trainer)
        return trainer
    }

    func recoverRunningJobs() async {
        guard !recovered else { return }
        recovered = true
        let sessions = await Task.detached(priority: .utility) { GaussianRecovery.sessions(requireCheckpoint: false) }.value
        let running = sessions.compactMap { session -> (GaussianRecoverySession, GaussianRunIntention)? in
            guard let intention = try? GaussianRunIntention.load(from: session.workspaceURL),
                  intention.shouldRecover(sessionState: session.state) else { return nil }
            return (session, intention)
        }.sorted {
            if $0.1.updatedAt != $1.1.updatedAt { return $0.1.updatedAt < $1.1.updatedAt }
            return $0.0.id.uuidString < $1.0.id.uuidString
        }
        for (session, _) in running {
            let worker = trainer(session: session)
            worker.continueAfterSystemInterruption()
        }
    }
}
