#ifndef FORMA_MEMORY_GUARD_HPP
#define FORMA_MEMORY_GUARD_HPP

#include <cstdint>
#include <limits>
#include <stdexcept>
#include <string>

#if defined(__APPLE__)
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
#include <os/proc.h>
#else
#include <mach/mach.h>
#include <mach/host_info.h>
#include <mach/vm_statistics.h>
#endif
#endif

// Byte arithmetic is checked before allocations or narrowing to platform sizes.
// These helpers and the guard introduce no population, image, or commercial quota.
inline uint64_t forma_checked_add_bytes(uint64_t left, uint64_t right,
                                        const char* phase = "Gaussian allocation") {
    if (right > std::numeric_limits<uint64_t>::max() - left) {
        throw std::runtime_error(std::string("Memory byte-count overflow during ") +
                                 (phase ? phase : "Gaussian allocation"));
    }
    return left + right;
}

inline uint64_t forma_checked_mul_bytes(uint64_t count, uint64_t stride,
                                        const char* phase = "Gaussian allocation") {
    if (stride != 0 && count > std::numeric_limits<uint64_t>::max() / stride) {
        throw std::runtime_error(std::string("Memory byte-count overflow during ") +
                                 (phase ? phase : "Gaussian allocation"));
    }
    return count * stride;
}

/// A fresh runtime snapshot, never cached. It is not an allocation reservation.
/// iOS reports remaining process dirty-memory allowance, not the device's total RAM.
/// macOS/simulator reports currently free + inactive (reclaimable) physical pages;
/// it cannot predict future compression, swap, other processes, or Metal resource limits.
inline uint64_t forma_runtime_available_memory_bytes() {
#if defined(__APPLE__) && TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
    return static_cast<uint64_t>(os_proc_available_memory());
#elif defined(__APPLE__)
    const mach_port_t host = mach_host_self();
    vm_size_t pageSize = 0;
    vm_statistics64_data_t statistics = {};
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    const kern_return_t pageResult = host_page_size(host, &pageSize);
    const kern_return_t statsResult = host_statistics64(
        host, HOST_VM_INFO64, reinterpret_cast<host_info64_t>(&statistics), &count);
    mach_port_deallocate(mach_task_self(), host);
    if (pageResult != KERN_SUCCESS || statsResult != KERN_SUCCESS || pageSize == 0) {
        throw std::runtime_error("Cannot query available/reclaimable physical memory for Gaussian allocation");
    }
    // free_count already includes speculative pages. Do not add speculative_count
    // or purgeable_count again: that would count overlapping page categories.
    const uint64_t pages = forma_checked_add_bytes(
        static_cast<uint64_t>(statistics.free_count),
        static_cast<uint64_t>(statistics.inactive_count), "runtime memory query");
    return forma_checked_mul_bytes(pages, static_cast<uint64_t>(pageSize), "runtime memory query");
#else
    throw std::runtime_error("Available-memory queries require an Apple platform");
#endif
}

/// extraBytes is the known *additional* peak needed after the call, not total usage.
/// Existing live allocations are already reflected in the runtime snapshot.
/// Call immediately before each large CPU/Metal allocation phase. A later allocation
/// can still fail; callers must keep their exception handling and checkpoint recovery.
inline void forma_require_available_memory(uint64_t extraBytes, const char* phase) {
    if (extraBytes == 0) return;
    const uint64_t available = forma_runtime_available_memory_bytes();
    if (extraBytes > available) {
        const std::string context = phase ? phase : "Gaussian allocation";
        throw std::runtime_error(
            "Insufficient runtime memory for " + context + ": " +
            std::to_string(extraBytes) + " additional bytes required; " +
            std::to_string(available) +
            " bytes currently available. Free memory or choose a different resolution "
            "and retry. No image or Gaussian quota has been applied.");
    }
}

#endif // FORMA_MEMORY_GUARD_HPP
