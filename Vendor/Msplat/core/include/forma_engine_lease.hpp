#pragma once
#include <atomic>
#include <stdexcept>

namespace forma {
/// Ownership belongs to the engine object, not the thread executing a Swift
/// continuation. std::mutex cannot stay locked across those thread hops.
class EngineLease {
    std::atomic_flag& occupied;
public:
    explicit EngineLease(std::atomic_flag& flag) : occupied(flag) {
        if (occupied.test_and_set(std::memory_order_acquire))
            throw std::runtime_error("Otra sesión de gaussianas sigue liberando recursos. Intenta de nuevo.");
    }
    ~EngineLease() { occupied.clear(std::memory_order_release); }
    EngineLease(const EngineLease&) = delete;
    EngineLease& operator=(const EngineLease&) = delete;
};
}
