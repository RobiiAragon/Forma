import Foundation
import Combine

/// Presentation state for a saved scan. Geometry, files and durable publication
/// remain owned by SavedScanRefinement, ProcessingControl and ScanStore.
@MainActor
final class ScanRefinementViewModel: ObservableObject {
    @Published var quality = LiDARQualitySettings()
    @Published private(set) var isRunning = false
    @Published private(set) var status = ""
    @Published private(set) var progress = 0.0
    @Published private(set) var saved: ScanRecord?
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?
    private var control: ProcessingControl?
    private var generation = UUID()
    private var isPublishing = false

    func start(scan: ScanRecord, store: ScanStore) {
        guard !isRunning, !store.isSaving, store.pendingCapture == nil else { return }
        do { try quality.validate() } catch { self.error = error.localizedDescription; return }
        let selected = quality, directory = store.directory(for: scan)
        let run = UUID(), gate = ProcessingControl()
        generation = run; control = gate; isRunning = true; isPublishing = false
        progress = 0; status = "Preparando una versión nueva"; saved = nil; error = nil
        task = Task {
            defer { isRunning = false; isPublishing = false; task = nil; control = nil }
            do {
                let result = try await SavedScanRefinement.process(scan: scan, directory: directory,
                    quality: selected, control: gate) { [weak self] title, fraction in
                    Task { @MainActor in
                        guard let self, self.generation == run, self.isRunning, !self.isPublishing else { return }
                        self.status = title; self.progress = fraction
                    }
                }
                if Task.isCancelled {
                    SavedScanRefinement.discardUnpublished(result)
                    return
                }
                isPublishing = true; status = "Guardando la versión nueva"
                if let output = await store.save(result) { saved = output; progress = 1; status = "Copia guardada" }
                else { error = store.error ?? "No se pudo guardar la versión nueva; las fuentes se conservan." }
            } catch is CancellationError { status = "Cancelado; captura original conservada" }
            catch { self.error = error.localizedDescription }
        }
    }

    func cancel() {
        task?.cancel()
        // ScanStore owns publication and its existing pause/cancel controls.
        // Cancelling this view's task must never cancel a different save.
        if !isPublishing { control?.cancel() }
    }
}
