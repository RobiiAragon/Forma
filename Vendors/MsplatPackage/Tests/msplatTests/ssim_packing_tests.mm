#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <array>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <vector>

namespace {
void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

struct Output {
    std::vector<float> gradient;
    std::vector<float> derivative;
    float loss;
};

Output run(id<MTLDevice> device, id<MTLCommandQueue> queue,
           const std::array<id<MTLComputePipelineState>,3>& pipeline,
           uint32_t width, uint32_t height, uint32_t stride) {
    const size_t pixels = static_cast<size_t>(width) * height;
    std::vector<float> rendered(pixels * 3), truth(pixels * 3);
    for (size_t i = 0; i < pixels; ++i) {
        for (size_t c = 0; c < 3; ++c) {
            rendered[i*3+c] = static_cast<float>((i * (13 + c*2) + 19*c) % 255) / 255;
            truth[i*3+c] = static_cast<float>((i * (7 + c*3) + 29*c + 11) % 255) / 255;
        }
    }
    id<MTLBuffer> image = [device newBufferWithBytes:rendered.data() length:rendered.size()*4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> gt = [device newBufferWithBytes:truth.data() length:truth.size()*4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> horizontal = [device newBufferWithLength:pixels*15*4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> derivative = [device newBufferWithLength:pixels*3*stride*4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> gradient = [device newBufferWithLength:pixels*3*4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> loss = [device newBufferWithLength:4 options:MTLResourceStorageModeShared];
    require(image && gt && horizontal && derivative && gradient && loss, "Synthetic test buffers must allocate");
    memset(derivative.contents, 0, derivative.length);
    memset(loss.contents, 0, loss.length);
    id<MTLCommandBuffer> command = [queue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
    const std::array<uint32_t,2> size{width,height};
    const float weight = .2f, invN = 1.f / static_cast<float>(pixels*3);
    const MTLSize groups = MTLSizeMake((width+15)/16, (height+15)/16,1);
    const MTLSize threads = MTLSizeMake(16,16,1);
    [encoder setComputePipelineState:pipeline[0]];
    [encoder setBuffer:image offset:0 atIndex:0]; [encoder setBuffer:gt offset:0 atIndex:1];
    [encoder setBytes:size.data() length:sizeof(size) atIndex:2];
    [encoder setBuffer:horizontal offset:0 atIndex:3];
    [encoder dispatchThreadgroups:groups threadsPerThreadgroup:threads];
    [encoder memoryBarrierWithScope:MTLBarrierScopeBuffers];
    [encoder setComputePipelineState:pipeline[1]];
    [encoder setBuffer:image offset:0 atIndex:0]; [encoder setBuffer:gt offset:0 atIndex:1];
    [encoder setBuffer:horizontal offset:0 atIndex:2];
    [encoder setBytes:size.data() length:sizeof(size) atIndex:3];
    [encoder setBytes:&weight length:4 atIndex:4]; [encoder setBytes:&invN length:4 atIndex:5];
    [encoder setBuffer:derivative offset:0 atIndex:6]; [encoder setBuffer:loss offset:0 atIndex:7];
    [encoder setBytes:&stride length:4 atIndex:8];
    [encoder dispatchThreadgroups:groups threadsPerThreadgroup:threads];
    [encoder memoryBarrierWithScope:MTLBarrierScopeBuffers];
    [encoder setComputePipelineState:pipeline[2]];
    [encoder setBuffer:image offset:0 atIndex:0]; [encoder setBuffer:gt offset:0 atIndex:1];
    [encoder setBuffer:derivative offset:0 atIndex:2];
    [encoder setBytes:size.data() length:sizeof(size) atIndex:3];
    [encoder setBytes:&weight length:4 atIndex:4]; [encoder setBytes:&invN length:4 atIndex:5];
    [encoder setBuffer:gradient offset:0 atIndex:6];
    [encoder setBytes:&stride length:4 atIndex:7];
    [encoder dispatchThreadgroups:groups threadsPerThreadgroup:threads];
    [encoder endEncoding];
    [command commit]; [command waitUntilCompleted];
    require(command.status == MTLCommandBufferStatusCompleted, "Actual Metal SSIM commands must complete");
    Output output;
    const float* gradients = static_cast<const float*>(gradient.contents);
    output.gradient.assign(gradients,gradients+pixels*3);
    const float* derivatives = static_cast<const float*>(derivative.contents);
    output.derivative.reserve(pixels*9);
    for (size_t pixel=0;pixel<pixels;++pixel) for (size_t c=0;c<3;++c) for (size_t f=0;f<3;++f) {
        output.derivative.push_back(derivatives[pixel*3*stride+c*stride+f]);
    }
    output.loss = *static_cast<const float*>(loss.contents) / pixels;
    [image release]; [gt release]; [horizontal release]; [derivative release]; [gradient release]; [loss release];
    return output;
}
} // namespace

int main(int argc, char* argv[]) {
    @autoreleasepool {
        try {
            id<MTLDevice> device = MTLCreateSystemDefaultDevice();
            require(device != nil, "Metal device must exist");
            const auto path = std::filesystem::canonical(argv[0]).parent_path() / "default.metallib";
            NSError* error = nil;
            id<MTLLibrary> library = [device newLibraryWithURL:[NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]] error:&error];
            require(library != nil, "Production metallib must load");
            const std::array<const char*,3> names{"ssim_h_fwd_kernel","ssim_fused_v_fwd_h_bwd_kernel","ssim_v_bwd_kernel"};
            std::array<id<MTLComputePipelineState>,3> pipeline{};
            for (size_t i=0;i<3;++i) {
                id<MTLFunction> function = [library newFunctionWithName:[NSString stringWithUTF8String:names[i]]];
                pipeline[i] = [device newComputePipelineStateWithFunction:function error:&error];
                [function release];
                require(pipeline[i] != nil,"Production SSIM pipeline must compile");
            }
            id<MTLCommandQueue> queue = [device newCommandQueue];
            size_t checkedPixels = 0;
            for (const auto size : {std::array<uint32_t,2>{1,1},{15,13},{16,16},{67,43},{80,64}}) {
                const Output reference = run(device,queue,pipeline,size[0],size[1],5);
                const Output packed = run(device,queue,pipeline,size[0],size[1],3);
                require(reference.gradient.size() == packed.gradient.size(),"All pixels/channels must remain present");
                require(std::memcmp(reference.gradient.data(),packed.gradient.data(),reference.gradient.size()*4)==0,
                        "Packed and stride-5 reference gradients must be bit-identical, including borders");
                require(std::memcmp(reference.derivative.data(),packed.derivative.data(),reference.derivative.size()*4)==0,
                        "All nine SSIM derivative fields must be bit-identical");
                for(float value:packed.gradient) require(std::isfinite(value),"Every gradient must be finite");
                const float delta = std::abs(reference.loss-packed.loss);
                // One group has one atomic addition and is exactly reproducible.
                // Multi-group sums can differ in their scheduling/order of additions.
                if(size[0]<=16 && size[1]<=16) require(delta==0,"Single-group losses must be bit-identical");
                else require(delta<=1e-6f,"Multi-group atomic loss reduction must retain floating-point agreement");
                std::cout<<size[0]<<'x'<<size[1]<<" bitExactGradients=true bitExactDerivatives=true lossDelta="<<delta<<'\n';
                checkedPixels += static_cast<size_t>(size[0])*size[1];
            }
            for(auto state:pipeline) [state release];
            [queue release]; [library release]; [device release];
            std::cout<<"PASS 5 actual Metal SSIM layouts; pixels="<<checkedPixels<<" native4KSavedBytes="<<(3840ull*2160*6*4)<<'\n';
            return 0;
        } catch(const std::exception& error) {
            std::cerr<<"FAIL "<<error.what()<<'\n';
            return 1;
        }
    }
}
