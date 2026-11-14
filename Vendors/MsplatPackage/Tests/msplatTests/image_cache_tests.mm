#include "input_data.hpp"
#include "msplat.hpp"
#include "forma_gaussian.h"
#include "model.hpp"
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <unistd.h>
#include <array>

namespace fs = std::filesystem;

namespace {
void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

void writeFixture(const fs::path& path, int width, int height) {
    std::vector<uint8_t> pixels(static_cast<size_t>(width) * height * 4);
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            const size_t i = (static_cast<size_t>(y) * width + x) * 4;
            pixels[i] = static_cast<uint8_t>((x * 13 + y * 3) % 256);
            pixels[i + 1] = static_cast<uint8_t>((y * 7 + x * 5) % 256);
            pixels[i + 2] = static_cast<uint8_t>((x + y * 11) % 256);
            pixels[i + 3] = 255;
        }
    }
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels.data(), width, height, 8,
        width * 4, colorSpace, kCGImageAlphaNoneSkipLast | kCGBitmapByteOrderDefault);
    CGColorSpaceRelease(colorSpace);
    require(context != nullptr, "Authored image context must exist");
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(nullptr,
        reinterpret_cast<const UInt8*>(path.c_str()), path.string().size(), false);
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, nullptr);
    CFRelease(url);
    require(destination != nullptr, "Authored PNG destination must exist");
    CGImageDestinationAddImage(destination, image, nullptr);
    const bool success = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CGImageRelease(image);
    require(success, "Authored PNG must save");
}

Camera fixtureCamera(const fs::path& path, int declaredWidth = 32, int declaredHeight = 32) {
    Camera camera;
    camera.width = declaredWidth; camera.height = declaredHeight;
    camera.fx = 28; camera.fy = 30; camera.cx = 15; camera.cy = 14;
    camera.filePath = path.string();
    return camera;
}

std::vector<float> copied(const MTensor& tensor) {
    const float* data = tensor.data<float>();
    return std::vector<float>(data, data + tensor.numel());
}

void testGPUOwnsPixelsAndReusesWithoutDecode(const fs::path& small) {
    std::vector<Camera> cameras{fixtureCamera(small)};
    CameraImageCache cache(2, 8 * 1024 * 1024);
    MTensor& tensor = cache.gpuImage(cameras, 0, 1);
    const auto reference = copied(tensor);
    const void* address = tensor.data_ptr();
    require(tensor.size(0) == 24 && tensor.size(1) == 32, "User source factor must stay at 2");
    require(cameras[0].image.empty() && cameras[0].imagePyramids.empty(), "No decoded CPU duplicate may remain after upload");
    require(cache.cachedBytes() == tensor.nbytes(), "Cache must account one float32 GPU image only");
    const float fx = cameras[0].fx, fy = cameras[0].fy, cx = cameras[0].cx, cy = cameras[0].cy;

    // Removing the file makes any accidental repeated decode fail immediately.
    const fs::path hidden = small.string() + ".held";
    fs::rename(small, hidden);
    try {
        Camera& calibrated = cache.ensureLoaded(cameras, 0);
        require(calibrated.image.empty(), "A render metadata lookup must not re-decode GPU-resident pixels");
        MTensor& again = cache.gpuImage(cameras, 0, 1);
        require(again.data_ptr() == address && copied(again) == reference, "Repeated camera must reuse the exact GPU pixels");
    } catch (...) {
        fs::rename(hidden, small);
        throw;
    }
    fs::rename(hidden, small);

    MTensor& coarse = cache.gpuImage(cameras, 0, 2);
    require(coarse.size(0) == 12 && coarse.size(1) == 16, "Pyramid stage changes must retain dataset factor");
    require(cameras[0].mtensorImageCache.size() == 1, "Earlier GPU pyramid stage must be released");
    require(cameras[0].image.empty() && cameras[0].imagePyramids.empty(), "Coarse upload must also release decoded copies");
    MTensor& restored = cache.gpuImage(cameras, 0, 1);
    require(copied(restored) == reference, "Reloading after pyramid eviction must retain every source pixel");
    require(cameras[0].fx == fx && cameras[0].fy == fy && cameras[0].cx == cx && cameras[0].cy == cy,
            "Metadata correction must not compound across reloads");
    const Image& cpu = cameras[0].getImage(1);
    require(cpu.width == 32 && cpu.height == 24 && cpu.data == reference,
            "A later CPU consumer must reload the same effective pixels and calibration");
}

void testEvictsBeforeNextDecode(const fs::path& small, const fs::path& folder) {
    std::vector<Camera> cameras{fixtureCamera(small), fixtureCamera(folder / "missing.png", 3840, 2160)};
    CameraImageCache cache(1, 8 * 1024);
    cache.gpuImage(cameras, 0, 1);
    require(!cameras[0].mtensorImageCache.empty(), "Fixture must have a resident camera before eviction");
    bool failed = false;
    try { cache.gpuImage(cameras, 1, 1); }
    catch (const std::exception&) { failed = true; }
    require(failed, "A missing second image must report an ordinary decode error");
    require(cameras[0].cachedImageBytes() == 0 && cache.cachedBytes() == 0,
            "Old camera must be evicted before the next decode starts, even when it fails");
}

void testDistortedReloadKeepsCalibrationAndPixels(const fs::path& small) {
    Camera camera = fixtureCamera(small);
    camera.k1 = 0.04f; camera.k2 = -0.005f; camera.p1 = 0.001f;
    std::vector<Camera> cameras{camera};
    CameraImageCache cache(1, 8 * 1024);
    MTensor& tensor = cache.gpuImage(cameras, 0, 1);
    const auto reference = copied(tensor);
    const int width = cameras[0].width, height = cameras[0].height;
    const float fx = cameras[0].fx, fy = cameras[0].fy, cx = cameras[0].cx, cy = cameras[0].cy;
    cameras[0].releaseImageMemory();
    MTensor& restored = cache.gpuImage(cameras, 0, 1);
    require(copied(restored) == reference, "Evicted distorted pixels must be reconstructed identically");
    require(cameras[0].width == width && cameras[0].height == height && cameras[0].fx == fx &&
            cameras[0].fy == fy && cameras[0].cx == cx && cameras[0].cy == cy,
            "Undistortion calibration must remain exact after eviction");
}

void testNative4KSingleImageResidency(const fs::path& image) {
    std::vector<Camera> cameras{fixtureCamera(image, 3840, 2160)};
    CameraImageCache cache(1, 128 * 1024 * 1024);
    MTensor& tensor = cache.gpuImage(cameras, 0, 1);
    const size_t expected = static_cast<size_t>(3840) * 2160 * 3 * sizeof(float);
    require(tensor.size(0) == 2160 && tensor.size(1) == 3840, "Residency budget must never lower native 4K resolution");
    require(cache.cachedBytes() == expected && cameras[0].image.empty(), "Native 4K residency must be one exact float GPU image");
    const float* rgb = tensor.data<float>();
    for (const size_t offset : {size_t(0), size_t(3840 * 13 + 71), size_t(3840 * 2159 + 3839)}) {
        for (size_t c = 0; c < 3; ++c) require(std::isfinite(rgb[offset * 3 + c]), "Native 4K pixels must remain finite");
    }
    std::cout << "native4KResidentBytes=" << cache.cachedBytes() << " previousCPUPlusGPUBytes=" << expected * 2 << '\n';
}

void testBridgeOperationPoolsKeepTrainingStateAlive(const fs::path& small, const fs::path& folder, const fs::path& library) {
    const fs::path dataset = folder / "dataset";
    const fs::path images = dataset / "images";
    fs::create_directories(images);
    fs::copy_file(small, images / "a.png");
    fs::copy_file(small, images / "b.png");
    std::ofstream(dataset / "cameras.txt") << "1 PINHOLE 64 48 56 56 32 24\n";
    std::ofstream(dataset / "images.txt") << "1 1 0 0 0 0 0 2 1 a.png\n\n2 1 0 0 0 0.08 0 2 1 b.png\n\n";
    std::ofstream points(dataset / "points3D.txt");
    for (int i = 1; i <= 32; ++i) {
        points << i << ' ' << (i % 8 - 4) * 0.02 << ' ' << (i / 8 - 2) * 0.02 << " 0 128 128 128 0\n";
    }
    points.close();
    char error[2048] = {};
    FormaGaussianHandle handle = forma_gaussian_create(dataset.c_str(), library.c_str(), 3, 1, error, sizeof(error));
    try {
        require(handle != nullptr, error);
        FormaGaussianStats stats{};
        for (int step = 1; step <= 2; ++step) {
            require(forma_gaussian_step(handle, &stats, error, sizeof(error)), error);
            require(stats.iteration == step && stats.splats == 32, "Pool boundaries must preserve trained state and full seed population");
        }
        const fs::path checkpoint = folder / "pooled-training.ckpt";
        require(forma_gaussian_checkpoint(handle, checkpoint.c_str(), error, sizeof(error)), error);
        forma_gaussian_destroy(handle);
        handle = nullptr;
        handle = forma_gaussian_create(dataset.c_str(), library.c_str(), 3, 1, error, sizeof(error));
        require(handle != nullptr, error);
        int32_t restoredStep = 0;
        require(forma_gaussian_resume(handle, checkpoint.c_str(), &restoredStep, error, sizeof(error)), error);
        require(restoredStep == 2, "Fresh context must resume at the exact checkpoint iteration");
        require(forma_gaussian_step(handle, &stats, error, sizeof(error)), error);
        require(stats.iteration == 3 && stats.splats == 32, "Resumed pooled operation must continue real Metal training");
        forma_gaussian_destroy(handle);
    } catch (...) {
        if (handle) forma_gaussian_destroy(handle);
        throw;
    }
}

std::vector<uint8_t> readBytes(const fs::path& path) {
    std::ifstream input(path,std::ios::binary);
    return std::vector<uint8_t>(std::istreambuf_iterator<char>(input),{});
}

void writeBytes(const fs::path& path,const std::vector<uint8_t>& data) {
    std::ofstream output(path,std::ios::binary);
    output.write(reinterpret_cast<const char*>(data.data()),data.size());
}

std::array<size_t,18> tensorOffsets(const std::vector<uint8_t>& bytes) {
    std::array<size_t,18> offsets{};
    size_t cursor=56;
    for(size_t i=0;i<18;++i) {
        uint32_t rank=0; std::memcpy(&rank,bytes.data()+cursor,4); cursor+=4+rank*8;
        uint64_t count=0; std::memcpy(&count,bytes.data()+cursor,8); cursor+=8;
        offsets[i]=cursor; cursor+=count;
        require(cursor<=bytes.size(),"Authored checkpoint tensor offsets must remain in bounds");
    }
    return offsets;
}

std::unique_ptr<Model> smallModel(const InputData& input) {
    return std::make_unique<Model>(input,2,0,3000,3,1000,2,0,1000,0,.01f,4000,.05f,3000,true,nullptr,3000);
}

void requireZero(const MTensor& tensor,const char* message) {
    const float* values=tensor.data<float>();
    for(int64_t i=0;i<tensor.numel();++i) require(values[i]==0,message);
}

void testDormantOptimizerRecoveryAndInvalidStateRejection(const fs::path& folder) {
    const InputData input=inputDataFromX((folder/"dataset").string());
    auto model=smallModel(input);
    for(int g=0;g<6;++g) {
        requireZero(model->adam_exp_avg[g],"Fresh first moments must initialize to zero");
        requireZero(model->adam_exp_avg_sq[g],"Fresh second moments must initialize to zero");
    }
    const fs::path healthy=folder/"healthy.ckpt";
    model->saveCheckpoint(healthy.string(),0);
    const auto reference=readBytes(healthy);
    const auto offsets=tensorOffsets(reference);
    auto invalid=reference;
    const float negative=-3.5f;
    std::memcpy(invalid.data()+offsets[16],&negative,4);
    const fs::path legacy=folder/"legacy-unused.ckpt";
    writeBytes(legacy,invalid);
    require(model->loadCheckpoint(legacy.string())==0,"Dormant legacy checkpoint must remain resumable");
    requireZero(model->featuresRest,"Recovery must preserve unused coefficients exactly");
    requireZero(model->adam_exp_avg[4],"Recovery must preserve first moments exactly");
    requireZero(model->adam_exp_avg_sq[4],"Only provably unused second moments can be reconstructed as zero");
    require(readBytes(legacy)==invalid,"Recovery must never modify the original checkpoint file");

    auto reject=[&](std::vector<uint8_t> bytes,const char* name,const char* expected) {
        const fs::path path=folder/name; writeBytes(path,bytes);
        bool failed=false;
        try { model->loadCheckpoint(path.string()); }
        catch(const std::exception& error) { failed=std::string(error.what()).find(expected)!=std::string::npos; }
        require(failed,"Invalid active/non-finite optimizer state must reject with its tensor diagnostic");
    };
    auto active=invalid;
    const uint32_t activatedStep=1000;
    std::memcpy(active.data()+8,&activatedStep,4); std::memcpy(active.data()+20,&activatedStep,4);
    reject(active,"active-negative.ckpt","adam_exp_avg_sq.featuresRest");
    auto nonfinite=invalid;
    const float nan=std::numeric_limits<float>::quiet_NaN();
    std::memcpy(nonfinite.data()+offsets[16],&nan,4);
    reject(nonfinite,"unused-nan.ckpt","non-finite tensor=adam_exp_avg_sq.featuresRest");
    auto trained=invalid; const float nonzeroCoefficient=.1f;
    std::memcpy(trained.data()+offsets[4],&nonzeroCoefficient,4);
    reject(trained,"trained-coefficient.ckpt","adam_exp_avg_sq.featuresRest");
    auto otherGroup=reference;
    std::memcpy(otherGroup.data()+offsets[12],&negative,4);
    reject(otherGroup,"active-mean-negative.ckpt","adam_exp_avg_sq.means");
}

void testMultipleDensificationsKeepUnusedMomentsZero(const fs::path& folder) {
    InputData input=inputDataFromX((folder/"dataset").string());
    auto model=smallModel(input);
    CameraImageCache images(1,128*1024*1024);
    for(int round=0;round<8;++round) {
        const int step=6+round*2;
        Camera& camera=images.ensureLoaded(input.cameras,0);
        MTensor& image=images.gpuImage(input.cameras,0,1);
        model->fullIteration(camera,step,image,.2f);
        model->validateFiniteState(step,"synthetic optimizer");
        const int count=model->num_active;
        model->xysGradNorm=gpu_zeros({count},DType::Float32);
        model->visCounts=gpu_zeros({count},DType::Float32);
        model->max2DSize=gpu_zeros({count},DType::Float32);
        for(int i=0;i<count;++i) {
            model->xysGradNorm.data<float>()[i]=1;
            model->visCounts.data<float>()[i]=1;
            model->opacities.data<float>()[i]=2; // Keep authored fixture points while forcing classification.
        }
        model->afterTrain(step);
        model->validateFiniteState(step,"synthetic densification");
        require(model->num_active>count,"Authored regression must exercise real Gaussian population growth");
        requireZero(model->featuresRest,"Inactive SH coefficients must stay zero across densification");
        requireZero(model->adam_exp_avg[4],"Inactive SH first moments must stay zero across densification");
        requireZero(model->adam_exp_avg_sq[4],"Inactive SH second moments must stay zero across densification");
    }
    require(model->num_active>4096,"Regression must grow beyond the initial backing-buffer slack");
}
} // namespace

int main(int argc, char* argv[]) {
    const fs::path folder = fs::temp_directory_path() / ("forma-native-cache-" + std::to_string(getpid()));
    try {
        fs::create_directories(folder);
        const fs::path small = folder / "authored64x48.png";
        const fs::path large = folder / "authored3840x2160.png";
        writeFixture(small, 64, 48);
        writeFixture(large, 3840, 2160);
        testGPUOwnsPixelsAndReusesWithoutDecode(small);
        testEvictsBeforeNextDecode(small, folder);
        testDistortedReloadKeepsCalibrationAndPixels(small);
        testNative4KSingleImageResidency(large);
        const fs::path library = fs::canonical(argv[0]).parent_path() / "default.metallib";
        testBridgeOperationPoolsKeepTrainingStateAlive(small, folder, library);
        testDormantOptimizerRecoveryAndInvalidStateRejection(folder);
        testMultipleDensificationsKeepUnusedMomentsZero(folder);
        fs::remove_all(folder);
        std::cout << "PASS 7 production cache, checkpoint recovery and densification regressions\n";
        return 0;
    } catch (const std::exception& error) {
        fs::remove_all(folder);
        std::cerr << "FAIL " << error.what() << '\n';
        return 1;
    }
}
