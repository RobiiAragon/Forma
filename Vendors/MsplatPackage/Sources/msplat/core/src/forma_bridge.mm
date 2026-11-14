// Forma adapter around the Apache-2.0 msplat C API. No exception crosses Swift.
#include "forma_gaussian.h"
#include "forma_engine_lease.hpp"
#include "msplat_c_api.h"
#include <Foundation/Foundation.h>
#include <filesystem>
#include <string>
#include <cstring>
#include <memory>
#include <cmath>
#include <stdexcept>
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
#include <malloc/malloc.h>
#endif

namespace {
std::atomic_flag engineLease = ATOMIC_FLAG_INIT;
struct Engine {
    forma::EngineLease lease;
    MsplatDataset dataset = nullptr;
    MsplatTrainer trainer = nullptr;
    Engine() : lease(engineLease) {}
    ~Engine() {
        if (trainer) msplat_trainer_destroy(trainer);
        if (dataset) msplat_dataset_destroy(dataset);
        msplat_cleanup();
    }
};
void message(char* dst, size_t capacity, const char* value) {
    if (!dst || capacity == 0) return;
    std::strncpy(dst, value ? value : "Error del motor Metal", capacity - 1);
    dst[capacity - 1] = 0;
}
template<typename F> bool safely(char* error, size_t capacity, F body) {
    // A Swift detached worker can keep its surrounding autorelease pool alive
    // across many steps. Drain Metal/Foundation factory objects at each native
    // operation boundary instead of letting completed command buffers retain
    // their transient resources until that outer worker eventually returns.
    @autoreleasepool {
        @try {
            try { body(); return true; }
            catch (const std::exception& e) { message(error, capacity, e.what()); }
            catch (...) { message(error, capacity, "Excepción desconocida en el entrenador"); }
        } @catch (NSException* exception) {
            message(error, capacity, exception.reason.UTF8String);
        }
        return false;
    }
}
Engine& checked(FormaGaussianHandle handle) {
    if (!handle) throw std::runtime_error("Entrenador no inicializado");
    return *static_cast<Engine*>(handle);
}
void relieveReleasedMemory() {
#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
    // Only free allocator-owned pages are reclaimed. Live Gaussian parameters,
    // textures and gradients remain intact. This runs after safely() drained
    // its autorelease pool and the GPU step completed, before Swift's rest.
    malloc_zone_pressure_relief(nullptr, 0);
#endif
}
}

FormaGaussianHandle forma_gaussian_create(const char* dataset, const char* metallib, int32_t iterations, float downscale, char* error, size_t capacity) {
    std::unique_ptr<Engine> engine;
    bool ok = safely(error, capacity, [&] {
        if (!dataset || !metallib || iterations <= 0 || !std::isfinite(downscale) || downscale < 1)
            throw std::runtime_error("Configuración de entrenamiento inválida");
        engine = std::make_unique<Engine>();
        msplat_set_metallib_path(metallib);
        engine->dataset = msplat_dataset_create(dataset, downscale, false, 8);
        if (msplat_dataset_num_train(engine->dataset) < 2)
            throw std::runtime_error("Se necesitan al menos dos imágenes calibradas");
        auto config = msplat_default_config();
        config.iterations = iterations;
        config.keepCrs = true;
        config.downscaleFactor = downscale;
        config.numDownscales = 0;
        // Upstream -1 silently stops densification halfway through the run.
        // Forma keeps it available throughout the user's requested run.
        config.stopDensifyAt = iterations;
        engine->trainer = msplat_trainer_create(engine->dataset, config);
    });
    relieveReleasedMemory();
    return ok ? engine.release() : nullptr;
}

bool forma_gaussian_step(FormaGaussianHandle handle, FormaGaussianStats* stats, char* error, size_t capacity) {
    const bool ok = safely(error, capacity, [&] {
        auto s = msplat_trainer_step(checked(handle).trainer);
        // Complete the GPU block before Swift measures work and begins its thermal duty-cycle rest.
        msplat_sync();
        if (stats) *stats = {s.iteration, s.splatCount, s.msPerStep};
    });
    relieveReleasedMemory();
    return ok;
}

bool forma_gaussian_stats(FormaGaussianHandle handle, FormaGaussianStats* stats, char* error, size_t capacity) {
    return safely(error, capacity, [&] {
        auto& engine = checked(handle);
        if (stats) *stats = {msplat_trainer_iteration(engine.trainer), msplat_trainer_splat_count(engine.trainer), 0};
    });
}

bool forma_gaussian_export(FormaGaussianHandle handle, const char* directory, char* error, size_t capacity) {
    return safely(error, capacity, [&] {
        auto& engine = checked(handle);
        if (msplat_trainer_iteration(engine.trainer) < 1) throw std::runtime_error("Aún no hay pasos de entrenamiento");
        std::filesystem::path folder(directory);
        std::filesystem::create_directories(folder);
        msplat_sync();
        msplat_trainer_export_ply(engine.trainer, (folder / "gaussianas.ply").c_str());
        msplat_trainer_export_splat(engine.trainer, (folder / "gaussianas.splat").c_str());
        msplat_trainer_save_checkpoint(engine.trainer, (folder / "entrenamiento.ckpt").c_str());
        for (auto name : {"gaussianas.ply", "gaussianas.splat", "entrenamiento.ckpt"}) {
            if (!std::filesystem::exists(folder / name) || std::filesystem::file_size(folder / name) == 0)
                throw std::runtime_error(std::string("No se creó ") + name);
        }
    });
}

bool forma_gaussian_checkpoint(FormaGaussianHandle handle, const char* path, char* error, size_t capacity) {
    return safely(error, capacity, [&] {
        msplat_sync();
        msplat_trainer_save_checkpoint(checked(handle).trainer, path);
    });
}

bool forma_gaussian_resume(FormaGaussianHandle handle, const char* path, int32_t* iteration, char* error, size_t capacity) {
    const bool ok = safely(error, capacity, [&] {
        int step = msplat_trainer_load_checkpoint(checked(handle).trainer, path);
        if (iteration) *iteration = step;
    });
    relieveReleasedMemory();
    return ok;
}

void forma_gaussian_destroy(FormaGaussianHandle handle) {
    char ignored[512];
    safely(ignored, sizeof(ignored), [&] { delete static_cast<Engine*>(handle); });
    relieveReleasedMemory();
}
