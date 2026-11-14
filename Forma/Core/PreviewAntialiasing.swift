import Foundation
import SceneKit

/// Sampling changes only edge coverage. It never simplifies the mesh or resizes photographs.
enum PreviewAntialiasing: Int, CaseIterable, Identifiable {
    case fluid = 1, balanced = 2, sharp = 4
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .fluid: return "Fluido · sin suavizado"
        case .balanced: return "Equilibrado · 2×"
        case .sharp: return "Nítido · 4×"
        }
    }

    func supportedSamples(_ supports: (Int) -> Bool) -> Int {
        Self.allCases.reversed().first { $0.rawValue <= rawValue && supports($0.rawValue) }?.rawValue ?? 1
    }

    static func sceneKitMode(samples: Int) -> SCNAntialiasingMode {
        switch samples {
        case 4: return .multisampling4X
        case 2: return .multisampling2X
        default: return .none
        }
    }
}
