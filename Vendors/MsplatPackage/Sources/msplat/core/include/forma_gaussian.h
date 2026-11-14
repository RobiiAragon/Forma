#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef void* FormaGaussianHandle;
typedef struct { int32_t iteration; int32_t splats; float milliseconds; } FormaGaussianStats;
FormaGaussianHandle forma_gaussian_create(const char* dataset, const char* metallib, int32_t iterations, float downscale, char* error, size_t errorCapacity);
bool forma_gaussian_step(FormaGaussianHandle handle, FormaGaussianStats* stats, char* error, size_t errorCapacity);
bool forma_gaussian_stats(FormaGaussianHandle handle, FormaGaussianStats* stats, char* error, size_t errorCapacity);
bool forma_gaussian_export(FormaGaussianHandle handle, const char* directory, char* error, size_t errorCapacity);
bool forma_gaussian_checkpoint(FormaGaussianHandle handle, const char* path, char* error, size_t errorCapacity);
bool forma_gaussian_resume(FormaGaussianHandle handle, const char* path, int32_t* iteration, char* error, size_t errorCapacity);
void forma_gaussian_destroy(FormaGaussianHandle handle);
void forma_gaussian_sort_diagnostics(int64_t* intersections, int64_t* densestTile);
#ifdef __cplusplus
}
#endif
