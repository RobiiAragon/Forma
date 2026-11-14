import ActivityKit
@preconcurrency import BackgroundTasks
import Foundation
import UIKit

/// A background grant is a scheduler decision, not a side effect of showing a Live Activity.
/// This token can be read by workers without crossing the main actor.
final class ProcessingExecutionLease: @unchecked Sendable {
    private let lock = NSLock()
    private var applicationActive: Bool
    private var backgroundGranted = false
    private var ended = false
    private var cpuOnlyForEntireJob = false
    private var reason: String
    private var activityAvailable = false
    private var activityStatus = "Aún no se ha solicitado la Live Activity."

    fileprivate init(applicationActive: Bool, reason: String) {
        self.applicationActive = applicationActive
        self.reason = reason
    }

    func setApplicationActive(_ active: Bool) {
        lock.lock(); defer { lock.unlock() }
        applicationActive = active
    }

    var canContinueInBackground: Bool {
        lock.lock(); defer { lock.unlock() }
        return backgroundGranted && !ended
    }

    var shouldUseCPUOnly: Bool {
        lock.lock(); defer { lock.unlock() }
        return cpuOnlyForEntireJob || !applicationActive
    }

    var backgroundReason: String {
        lock.lock(); defer { lock.unlock() }
        return reason
    }

    /// Confirms that Activity.request created an activity, not that the system
    /// actually rendered the widget on the Lock Screen or Dynamic Island.
    var liveActivityAvailable: Bool {
        lock.lock(); defer { lock.unlock() }
        return activityAvailable
    }

    var liveActivityStatus: String {
        lock.lock(); defer { lock.unlock() }
        return activityStatus
    }

    fileprivate func recordLiveActivity(available: Bool, status: String) {
        lock.lock(); defer { lock.unlock() }
        activityAvailable = available
        activityStatus = status
    }

    fileprivate func grantCPUBackground() {
        lock.lock(); defer { lock.unlock() }
        guard !ended else { return }
        backgroundGranted = true
        cpuOnlyForEntireJob = true
        reason = "iOS autorizó continuar con CPU en segundo plano."
    }

    fileprivate func fallback(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        backgroundGranted = false
        reason = message
    }

    fileprivate func finish() {
        lock.lock(); defer { lock.unlock() }
        backgroundGranted = false
        ended = true
    }
}

@MainActor
final class ProcessingActivityCoordinator {
    static let shared = ProcessingActivityCoordinator()
    private static let schedulerPrefix = "com.robii.forma.processing."
    private static let actionNotification = Notification.Name("FormaProcessingActivityAction")

    private final class Session {
        let id: UUID
        let title: String
        let generation = UUID()
        let lease: ProcessingExecutionLease
        let onAction: (String) -> Void
        let onExpiration: () -> Void
        var state: FormaProcessingAttributes.ContentState
        var activity: Activity<FormaProcessingAttributes>?
        var activityQueue: Task<Void, Never>?
        var flushTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?
        var beginContinuation: CheckedContinuation<ProcessingExecutionLease, Never>?
        var backgroundTask: AnyObject?
        var lastPublish = -Double.greatestFiniteMagnitude
        var lastBackgroundSubtitleKey: String?
        var finished = false
        var backgroundRequestTimedOut = false
        var activityRequestAttempted = false
        var activityWaitingForForeground = false

        init(id: UUID, title: String, lease: ProcessingExecutionLease,
             onAction: @escaping (String) -> Void, onExpiration: @escaping () -> Void) {
            self.id = id
            self.title = title
            self.lease = lease
            self.onAction = onAction
            self.onExpiration = onExpiration
            state = .init(progress: 0, status: "Preparando…", phase: "running", energyLabel: "")
        }
    }

    private var configured = false
    private var sessions: [UUID: Session] = [:]
    /// A fresh generation UUID makes every request unambiguous, even if an app-level
    /// job identifier is reused after cancellation or a foreground fallback.
    private var backgroundRequestOwners: [UUID: UUID] = [:]
    private var actionObserver: NSObjectProtocol?

    private init() {}

    /// Call once from app startup. Continued-processing handlers are registered for
    /// each concrete request at submission time, not for the Info.plist wildcard.
    func configure() {
        guard !configured else { return }
        configured = true
        actionObserver = NotificationCenter.default.addObserver(
            forName: Self.actionNotification, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated { self?.receiveAction(notification) }
            }
        // Activities can outlive a terminated process. Their old pause controls must
        // not imply that an in-memory worker still exists after a fresh launch.
        for activity in Activity<FormaProcessingAttributes>.activities {
            var state = activity.content.state
            state.phase = "failed"
            state.status = "Procesamiento interrumpido. Abre Forma para revisar el trabajo."
            Task {
                await activity.end(.init(state: state, staleDate: nil),
                                   dismissalPolicy: .after(Date().addingTimeInterval(30)))
            }
        }
    }

    /// The caller starts its worker only after this returns. A true lease is issued only
    /// from the scheduler's actual launch handler, never merely from successful submission.
    func begin(id: UUID, title: String, requiresGPU: Bool = false,
               onAction: @escaping (String) -> Void,
               onExpiration: @escaping () -> Void) async -> ProcessingExecutionLease {
        configure()
        if let existing = sessions[id], !existing.finished { return existing.lease }
        let lease = ProcessingExecutionLease(applicationActive: UIApplication.shared.applicationState == .active,
                                             reason: "El trabajo se pausa al salir de Forma.")
        let session = Session(id: id, title: title, lease: lease,
                              onAction: onAction, onExpiration: onExpiration)
        sessions[id] = session

        guard !requiresGPU else {
            lease.fallback("Este trabajo usa Metal. La firma actual no autoriza GPU en segundo plano; se pausa al salir de Forma.")
            startActivity(session)
            return lease
        }
        guard #available(iOS 26.0, *) else {
            lease.fallback("Esta versión de iOS permite mostrar el progreso, pero el trabajo se pausa al salir de Forma.")
            startActivity(session)
            return lease
        }
        guard UIApplication.shared.applicationState == .active else {
            lease.fallback("iOS no concedió ejecución continua; el trabajo se pausa al salir de Forma.")
            startActivity(session)
            return lease
        }
        let requestIdentifier = Self.schedulerPrefix + session.generation.uuidString
        guard registerBackgroundHandler(identifier: requestIdentifier) else {
            lease.fallback("iOS no permitió registrar esta tarea; el trabajo se pausa al salir de Forma.")
            startActivity(session)
            return lease
        }

        return await withCheckedContinuation { continuation in
            session.beginContinuation = continuation
            backgroundRequestOwners[session.generation] = id
            session.timeoutTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(8)) }
                catch { return }
                self?.submissionTimedOut(id: id, generation: session.generation)
            }
            let request = BGContinuedProcessingTaskRequest(
                identifier: requestIdentifier,
                title: title, subtitle: "Preparando procesamiento local…")
            request.strategy = .fail
            // Default resources grant CPU/network only. This implementation does not
            // request GPU or Neural Engine capabilities that are absent from the signature.
            let generation = session.generation
            Task.detached(priority: .utility) { [weak self] in
                do {
                    if #available(iOS 27.0, *) {
                        try await BGTaskScheduler.shared.submitTaskRequest(request)
                    } else {
                        try BGTaskScheduler.shared.submit(request)
                    }
                } catch {
                    await self?.submissionFailed(id: id, generation: generation, error: error)
                }
            }
        }
    }

    @available(iOS 26.0, *)
    private func registerBackgroundHandler(identifier: String) -> Bool {
        // The permitted Info.plist entry ends in `.*`, but both register and submit
        // need this same fully composed UUID identifier. Registrations cannot be
        // removed; capture only the coordinator weakly, never the session or worker.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { [weak self] task in
            guard let continued = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor [weak self] in
                guard let self else {
                    continued.setTaskCompleted(success: false)
                    return
                }
                self.receiveBackgroundTask(continued)
            }
        }
    }

    func update(id: UUID, progress: Double, status: String, phase: String, energyLabel: String) {
        guard let session = sessions[id], !session.finished else { return }
        let previousPhase = session.state.phase
        let validPhases = ["running", "pausing", "paused", "pausedForeground", "saving", "completed", "failed"]
        let bounded = progress.isFinite ? min(1, max(0, progress)) : session.state.progress
        session.state = .init(progress: bounded, status: status,
                              phase: validPhases.contains(phase) ? phase : "running", energyLabel: energyLabel)
        let elapsed = ProcessInfo.processInfo.systemUptime - session.lastPublish
        if previousPhase != session.state.phase || elapsed >= 1 || bounded >= 1 {
            session.flushTask?.cancel(); session.flushTask = nil
            publish(session)
        } else if session.flushTask == nil {
            let generation = session.generation
            session.flushTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(max(0.01, 1 - elapsed))) }
                catch { return }
                guard let self, let active = self.sessions[id], active.generation == generation,
                      !active.finished else { return }
                active.flushTask = nil
                self.publish(active)
            }
        }
    }

    func finish(id: UUID, success: Bool, status: String) {
        guard let session = sessions[id], !session.finished else { return }
        session.finished = true
        session.flushTask?.cancel(); session.flushTask = nil
        session.timeoutTask?.cancel(); session.timeoutTask = nil
        session.lease.finish()
        session.state.status = status
        session.state.phase = success ? "completed" : "failed"
        if success { session.state.progress = 1 }

        if #available(iOS 26.0, *), let task = session.backgroundTask as? BGContinuedProcessingTask {
            session.backgroundTask = nil
            task.expirationHandler = nil
            task.updateTitle(session.title, subtitle: status)
            if success { task.progress.completedUnitCount = task.progress.totalUnitCount }
            task.setTaskCompleted(success: success)
        } else if backgroundRequestOwners[session.generation] == id {
            if #available(iOS 26.0, *) {
                BGTaskScheduler.shared.cancel(
                    taskRequestWithIdentifier: Self.schedulerPrefix + session.generation.uuidString)
            }
        }
        backgroundRequestOwners.removeValue(forKey: session.generation)
        resolveBegin(session)
        if let activity = session.activity {
            let previous = session.activityQueue
            let content = ActivityContent(state: session.state, staleDate: nil)
            session.activityQueue = Task { @MainActor in
                await previous?.value
                await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(30)))
            }
        }
        sessions.removeValue(forKey: id)
    }

    private func receiveAction(_ notification: Notification) {
        guard let rawID = notification.userInfo?["jobID"] as? String,
              let id = UUID(uuidString: rawID), let session = sessions[id], !session.finished,
              let action = notification.userInfo?["action"] as? String,
              action == "pause" || action == "resume" else { return }
        session.onAction(action)
    }

    private func startActivity(_ session: Session) {
        guard !session.finished, session.activity == nil, !session.activityRequestAttempted else { return }
        guard UIApplication.shared.applicationState == .active else {
            if !session.activityWaitingForForeground {
                session.activityWaitingForForeground = true
                session.lease.recordLiveActivity(available: false,
                    status: "No se solicitó la Live Activity: Forma no estaba en primer plano. Se intentará una vez cuando vuelva y haya otra actualización.")
                debugLiveActivity("foreground-required")
            }
            return
        }
        session.activityRequestAttempted = true
        session.activityWaitingForForeground = false
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            session.lease.recordLiveActivity(available: false,
                status: "ActivityAuthorizationInfo.areActivitiesEnabled es false; iOS no permite Live Activities para Forma.")
            debugLiveActivity("activities-disabled")
            return
        }
        do {
            session.activity = try Activity.request(
                attributes: FormaProcessingAttributes(jobID: session.id, title: session.title),
                content: .init(state: session.state, staleDate: nil, relevanceScore: 100), pushType: nil)
            let state = session.activity.map { String(describing: $0.activityState) } ?? "unknown"
            session.lease.recordLiveActivity(available: session.activity != nil,
                status: "Activity.request aceptada; estado inicial: \(state). La presentación visual depende de iOS y la extensión.")
            debugLiveActivity("request-accepted state=\(state)")
        } catch {
            let details = error as NSError
            session.lease.recordLiveActivity(available: false,
                status: "Activity.request falló: \(String(reflecting: error)); dominio=\(details.domain); código=\(details.code); \(details.localizedDescription)")
            debugLiveActivity("request-rejected", error: details)
            // Showing the activity and receiving execution time are independent. The
            // app's existing progress and pause controls remain available on failure.
        }
    }

    private func debugLiveActivity(_ event: String, error: NSError? = nil) {
        #if DEBUG
        // Only framework outcomes are logged. Never log job IDs, titles, scene
        // names, paths, attribute payloads, or the error's userInfo dictionary.
        if let error {
            NSLog("Forma LiveActivity: %@; domain=%@; code=%ld", event, error.domain, error.code)
        } else {
            NSLog("Forma LiveActivity: %@", event)
        }
        #endif
    }

    private func publish(_ session: Session) {
        guard !session.finished else { return }
        // A grant may arrive after the user backgrounds Forma. Request at most
        // once when a later real update finds it foregrounded; never fabricate
        // progress or repeatedly retry an authorization/request error.
        if session.activity == nil, !session.activityRequestAttempted,
           UIApplication.shared.applicationState == .active {
            startActivity(session)
        }
        session.lastPublish = ProcessInfo.processInfo.systemUptime
        let state = session.state
        if #available(iOS 26.0, *), let task = session.backgroundTask as? BGContinuedProcessingTask {
            let progress = task.progress
            let completed = Int64((min(1, max(0, state.progress)) * 10_000).rounded())
            if progress.completedUnitCount != completed { progress.completedUnitCount = completed }
            // Keep every real progress advance. The system may prioritize its
            // own card, so also show a real percentage there, coalesced to five
            // percentage points or a phase change rather than every block.
            let subtitle: String
            switch state.phase {
            case "pausing": subtitle = "Pausando el procesamiento…"
            case "paused": subtitle = "Procesamiento en pausa"
            case "pausedForeground": subtitle = "En pausa · abre Forma para continuar"
            case "saving": subtitle = "Guardando el resultado"
            case "completed": subtitle = "Procesamiento completado"
            case "failed": subtitle = "Procesamiento detenido"
            default: subtitle = "Procesamiento local en curso"
            }
            let percent = Int((min(1, max(0, state.progress)) * 100).rounded(.down))
            let key = "\(state.phase):\(percent / 5)"
            if session.lastBackgroundSubtitleKey != key {
                task.updateTitle(session.title, subtitle: "\(subtitle) · \(percent) %")
                session.lastBackgroundSubtitleKey = key
            }
        }
        guard let activity = session.activity else { return }
        let previous = session.activityQueue
        session.activityQueue = Task { @MainActor in
            await previous?.value
            guard !session.finished else { return }
            await activity.update(.init(state: state, staleDate: nil, relevanceScore: 100))
        }
    }

    private func resolveBegin(_ session: Session) {
        session.timeoutTask?.cancel(); session.timeoutTask = nil
        let continuation = session.beginContinuation
        session.beginContinuation = nil
        // The scheduler has now either granted or denied this request. Creating
        // our interactive activity after its system activity gives iOS the latest
        // relevant presentation before the caller begins real processing.
        if continuation != nil, !session.finished { startActivity(session) }
        continuation?.resume(returning: session.lease)
    }

    private func submissionTimedOut(id: UUID, generation: UUID) {
        guard let session = sessions[id], session.generation == generation,
              session.beginContinuation != nil, session.backgroundTask == nil else { return }
        session.backgroundRequestTimedOut = true
        backgroundRequestOwners.removeValue(forKey: generation)
        session.lease.fallback("iOS no inició la tarea a tiempo. El trabajo se pausa al salir de Forma.")
        if #available(iOS 26.0, *) {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.schedulerPrefix + generation.uuidString)
        }
        resolveBegin(session)
    }

    private func submissionFailed(id: UUID, generation: UUID, error: Error) {
        guard let session = sessions[id], session.generation == generation,
              session.beginContinuation != nil, session.backgroundTask == nil else { return }
        session.lease.fallback("iOS no autorizó continuar en segundo plano: \(error.localizedDescription)")
        backgroundRequestOwners.removeValue(forKey: generation)
        resolveBegin(session)
    }

    @available(iOS 26.0, *)
    private func receiveBackgroundTask(_ task: BGContinuedProcessingTask) {
        guard task.identifier.hasPrefix(Self.schedulerPrefix),
              let requestID = UUID(uuidString: String(task.identifier.dropFirst(Self.schedulerPrefix.count))),
              let id = backgroundRequestOwners[requestID],
              let session = sessions[id], !session.finished,
              session.generation == requestID, !session.backgroundRequestTimedOut,
              session.beginContinuation != nil, session.backgroundTask == nil else {
            task.setTaskCompleted(success: false)
            return
        }
        session.backgroundTask = task
        task.progress.totalUnitCount = 10_000
        task.progress.completedUnitCount = 0
        let generation = session.generation
        task.expirationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                self?.expired(id: id, generation: generation)
            }
        }
        session.lease.grantCPUBackground()
        publish(session)
        resolveBegin(session)
    }

    private func expired(id: UUID, generation: UUID) {
        guard let session = sessions[id], session.generation == generation, !session.finished else { return }
        session.onExpiration()
        finish(id: id, success: false, status: "iOS detuvo el procesamiento. El original se conserva.")
    }
}
