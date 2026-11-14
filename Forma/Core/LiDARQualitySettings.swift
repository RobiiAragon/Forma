import Foundation

/// Sampling and geometric filtering are independent of the sensor's physical resolution.
/// Persisted with sources so hybrid and standalone processing use the same choices.
struct LiDARQualitySettings: Codable, Equatable, Sendable {
    var nativePlaneAssistance = false
    var densePhotographs = false
    var correctPlanarNoise = false
    var planarToleranceMeters: Float = 0.003

    var translationBetweenPhotos: Float { densePhotographs ? 0.03 : 0.06 }
    var angleBetweenPhotos: Float { densePhotographs ? 0.035 : 0.07 }

    func validate() throws {
        guard planarToleranceMeters.isFinite, planarToleranceMeters > 0 else {
            throw RGBDDatasetError.invalid("La tolerancia de paredes debe ser una distancia positiva en metros.")
        }
    }

    var planarConfiguration: MeshPlanarDenoiser.Configuration {
        var configuration = MeshPlanarDenoiser.Configuration()
        configuration.enabled = correctPlanarNoise
        configuration.toleranceMeters = Double(planarToleranceMeters)
        return configuration
    }
}
