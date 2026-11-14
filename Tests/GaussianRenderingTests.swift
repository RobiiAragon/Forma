import XCTest
import Metal
import simd
@testable import Forma

final class GaussianRenderingTests: XCTestCase {
    private struct Camera {
        var view: simd_float4x4
        var projection: simd_float4x4
        var viewport: SIMD4<Float>
        var eyeAndDegree: SIMD4<Float>
    }

    func testMetalRendersAnisotropicCovarianceAndRotation() throws {
        let unrotated = try render(rotation: SIMD4(0,0,0,1))
        let rotated = try render(rotation: SIMD4(0,0,sin(.pi/4),cos(.pi/4)))
        func green(_ data: [UInt8], x: Int, y: Int) -> UInt8 { data[(y*64+x)*4+1] }
        XCTAssertGreaterThan(green(unrotated,x:32,y:32),150, "SH0 produces a visible green Gaussian, not points or a textured quad")
        XCTAssertGreaterThan(green(unrotated,x:40,y:32),green(unrotated,x:32,y:40)+20,
            "Anisotropic covariance must elongate the Gaussian along X")
        XCTAssertGreaterThan(green(rotated,x:32,y:40),green(rotated,x:40,y:32)+20,
            "Quaternion rotation must rotate the projected covariance")
    }

    func testMetalUsesHigherSHBandsForViewDependentColor() throws {
        var coefficients = [SIMD4<Float>](repeating: .zero, count: 16)
        coefficients[15] = SIMD4(0.5, 0, 0, 0)
        let left = try render(rotation: SIMD4(0,0,0,1), coefficients: coefficients, degree: 3, eye: SIMD3(2,0,-2))
        let right = try render(rotation: SIMD4(0,0,0,1), coefficients: coefficients, degree: 3, eye: SIMD3(-2,0,-2))
        let center = (32 * 64 + 32) * 4
        XCTAssertGreaterThan(Int(left[center]) - Int(right[center]), 80,
                             "SH3 changes color with viewing direction instead of displaying only DC color")
        XCTAssertLessThanOrEqual(abs(Int(left[center + 1]) - Int(right[center + 1])), 1)
    }

    func testMetalRejectsOverflowingCovarianceWithoutInvalidVertices() throws {
        let pixels = try render(rotation: SIMD4(0,0,0,1), scale: SIMD3(repeating: .greatestFiniteMagnitude))
        XCTAssertTrue(pixels.allSatisfy { $0 == 0 }, "Unrepresentable projected covariance must be culled safely")
    }

    func testNearOffscreenGaussianCannotExpandAcrossTheObservedImage() throws {
        let reference = try render(rotation: SIMD4(0,0,0,1))
        let offscreen = GaussianPoint(positionOpacity: SIMD4(5,0,-0.015,0.99),
            scale: SIMD4(0.1,0.1,0.1,0), rotation: SIMD4(0,0,0,1), color: SIMD4(1,0,0,1))
        let observed = try render(rotation: SIMD4(0,0,0,1), offscreen: offscreen)
        let center = (32 * 64 + 32) * 4
        XCTAssertGreaterThan(reference[center + 1], 150)
        for channel in 0..<3 {
            XCTAssertEqual(observed[center + channel], reference[center + channel],
                           "Offscreen covariance must use the same frustum linearization as training, without deleting the point.")
        }
    }

    private func render(rotation: SIMD4<Float>, scale: SIMD3<Float> = SIMD3(0.2,0.04,0.01),
                        coefficients: [SIMD4<Float>]? = nil, degree: Float = 0,
                        eye: SIMD3<Float> = .zero, offscreen: GaussianPoint? = nil) throws -> [UInt8] {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal no disponible") }
        let library = try device.makeDefaultLibrary(bundle: Bundle.main)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = try XCTUnwrap(library.makeFunction(name: "formaGaussianVertex"))
        descriptor.fragmentFunction = try XCTUnwrap(library.makeFunction(name: "formaGaussianFragment"))
        descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width:64,height:64,mipmapped:false)
        textureDescriptor.usage = .renderTarget
        textureDescriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: textureDescriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red:0,green:0,blue:0,alpha:0)
        let point = GaussianPoint(positionOpacity: SIMD4(0,0,-2,0.9),scale:SIMD4(scale,0),rotation:rotation,color:SIMD4(0,1,0,1))
        let points = [point] + (offscreen.map { [$0] } ?? [])
        let indices = points.indices.map { UInt32($0) } // Far green, then the near offscreen point.
        var sh = [SIMD4<Float>](repeating:.zero,count:16)
        sh[0] = SIMD4(-0.5/0.2820948,0.5/0.2820948,-0.5/0.2820948,0)
        if let coefficients { sh = coefficients }
        if offscreen != nil {
            var red = [SIMD4<Float>](repeating: .zero,count: 16)
            red[0] = SIMD4(0.5/0.2820948,-0.5/0.2820948,-0.5/0.2820948,0)
            sh += red
        }
        let f:Float = 1/tan(.pi/6), n:Float=0.001, far:Float=100
        let projection = simd_float4x4(columns:(SIMD4(f,0,0,0),SIMD4(0,f,0,0),SIMD4(0,0,far/(n-far),-1),SIMD4(0,0,far*n/(n-far),0)))
        var camera = Camera(view:matrix_identity_float4x4,projection:projection,viewport:SIMD4(64,64,32*f,32*f),eyeAndDegree:SIMD4(eye,degree))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor:pass))
        encoder.setRenderPipelineState(pipeline)
        points.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!,length:$0.count,index:0) }
        indices.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!,length:$0.count,index:1) }
        encoder.setVertexBytes(&camera,length:MemoryLayout<Camera>.stride,index:2)
        sh.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!,length:$0.count,index:3) }
        encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:points.count)
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        XCTAssertEqual(command.status,.completed,command.error?.localizedDescription ?? "GPU error")
        var pixels = [UInt8](repeating:0,count:64*64*4)
        pixels.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!,bytesPerRow:64*4,from:MTLRegionMake2D(0,0,64,64),mipmapLevel:0) }
        return pixels
    }
}
