#include "forma_gaussian.h"
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <stdexcept>

// Optional local acceptance fixture. Dataset/checkpoint are read-only; the
// caller supplies an owned output directory. Not registered as a CTest case.
int main(int argc, char* argv[]) {
    if (argc != 5) {
        std::cerr << "Usage: msplat_room_finite_probe DATASET CHECKPOINT OWNED_OUTPUT STEPS\n";
        return 2;
    }
    namespace fs = std::filesystem;
    const fs::path dataset = argv[1], checkpoint = argv[2], output = argv[3];
    const fs::path library = fs::canonical(argv[0]).parent_path() / "default.metallib";
    fs::create_directories(output);
    setenv("MSPLAT_VALIDATE_EVERY_STEP","1",1);
    setenv("MSPLAT_MEM_LOG_EVERY","10",1);
    char error[2048] = {};
    FormaGaussianHandle handle = forma_gaussian_create(dataset.c_str(),library.c_str(),3000,1,error,sizeof(error));
    if (!handle) { std::cerr << "FAIL create " << error << '\n'; return 1; }
    int32_t resumed = 0;
    if (!forma_gaussian_resume(handle,checkpoint.c_str(),&resumed,error,sizeof(error))) {
        std::cerr << "FAIL resume " << error << '\n'; forma_gaussian_destroy(handle); return 1;
    }
    std::cout << "Finite checkpoint resumed=" << resumed << '\n'; std::cout.flush();
    FormaGaussianStats stats{};
    for (int i = 0; i < std::atoi(argv[4]); ++i) {
        if (!forma_gaussian_step(handle,&stats,error,sizeof(error))) {
            std::cerr << "FAIL step after " << stats.iteration << ": " << error << '\n';
            forma_gaussian_destroy(handle); return 1;
        }
        std::cout << "finite step=" << stats.iteration << " gaussians=" << stats.splats << '\n'; std::cout.flush();
    }
    const fs::path saved = output / "acceptance.ckpt";
    if (!forma_gaussian_checkpoint(handle,saved.c_str(),error,sizeof(error))) {
        std::cerr << "FAIL checkpoint " << error << '\n'; forma_gaussian_destroy(handle); return 1;
    }
    forma_gaussian_destroy(handle);
    std::cout << "PASS finite trained state and checkpoint at " << stats.iteration << '\n';
    return 0;
}
