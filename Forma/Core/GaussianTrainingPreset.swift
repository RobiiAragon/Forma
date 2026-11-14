import Foundation

/// Visible shortcuts for the existing training controls, never engine limits.
/// These budgets describe appearance optimization, not geometric accuracy.
enum GaussianTrainingPreset: String, CaseIterable, Identifiable {
    case preview, balanced, detail
    var id: String { rawValue }
    var title: String {
        switch self {
        case .preview: return "Vista previa"
        case .balanced: return "Equilibrado"
        case .detail: return "Más detalle"
        }
    }
    var iterations: Int {
        switch self {
        case .preview: return 1_000
        case .balanced: return 3_000
        case .detail: return 10_000
        }
    }
    var downscale: Float { self == .preview ? 2 : 1 }
    func apply(iterations: inout String, downscale: inout String, preservingScale: Bool) {
        iterations = String(self.iterations)
        if !preservingScale { downscale = String(format: "%g", self.downscale) }
    }
    static let explanation = "Vista previa: 1.000 pasos, factor 2. Equilibrado: 3.000, factor 1. Más detalle: 10.000, factor 1. Son puntos de partida editables: más pasos no garantizan mejor apariencia ni precisión geométrica."
}
