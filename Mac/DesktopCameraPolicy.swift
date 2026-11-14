import SceneKit
import simd

/// Clipping follows the camera and the normalized content, including inspection
/// from inside a room. It never changes the mesh or disables backface culling.
enum DesktopCameraPolicy {
    struct Range {
        let near: Double
        let far: Double
    }

    static func clippingRange(contentRadius: Double, cameraDistance: Double) -> Range {
        let radius = contentRadius.isFinite && contentRadius > 0 ? contentRadius : 1.2
        let distance = cameraDistance.isFinite && cameraDistance >= 0 ? cameraDistance : 0
        // A small positive near plane is required by the perspective projection.
        // Outside the content sphere, increase it safely to retain depth precision.
        let near = max(radius * 0.0005, max(0, distance - radius) * 0.25)
        let far = max(near * 4, (distance + radius) * 1.1)
        return Range(near: near, far: far)
    }

    static func apply(to camera: SCNCamera, cameraPosition: SIMD3<Float>, contentRadius: Double) {
        let position = SIMD3<Double>(Double(cameraPosition.x), Double(cameraPosition.y), Double(cameraPosition.z))
        let range = clippingRange(contentRadius: contentRadius, cameraDistance: simd_length(position))
        camera.automaticallyAdjustsZRange = false
        camera.zNear = range.near
        camera.zFar = range.far
    }

    /// Optical zoom avoids dollying through the surface or past the orbit target.
    static func zoomFieldOfView(current: Double, logScale: Double) -> Double {
        let field = current.isFinite && current > 0 && current < 180 ? current : 60
        guard logScale.isFinite else { return field }
        let halfTangent = tan(field * .pi / 360) * exp(-max(-20, min(20, logScale)))
        // Keep the perspective projection finite; these are camera angles, not
        // limits on model detail, texture pixels, or exported geometry.
        let minimum = tan(0.05 * Double.pi / 360), maximum = tan(140.0 * Double.pi / 360)
        return atan(max(minimum, min(maximum, halfTangent))) * 360 / .pi
    }

    static func zoomAnchorShift(oldFieldOfView: Double, newFieldOfView: Double,
                                viewport: SIMD2<Double>, point: SIMD2<Double>, depth: Double,
                                horizontalProjection: Bool) -> SIMD3<Float> {
        guard viewport.x > 0, viewport.y > 0, depth.isFinite, depth > 0 else { return .zero }
        let aspect = viewport.x / viewport.y
        let oldTangent = tan(oldFieldOfView * .pi / 360)
        let newTangent = tan(newFieldOfView * .pi / 360)
        let xScale = horizontalProjection ? 1 : aspect
        let yScale = horizontalProjection ? 1/aspect : 1
        let x = (2 * point.x / viewport.x - 1) * (oldTangent - newTangent) * xScale * depth
        let y = (2 * point.y / viewport.y - 1) * (oldTangent - newTangent) * yScale * depth
        return SIMD3(Float(x), Float(y), 0)
    }
}
