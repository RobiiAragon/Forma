#include "forma_engine_lease.hpp"
#include <atomic>
#include <cassert>
#include <iostream>
#include <memory>
#include <thread>
#include <vector>

int main() {
    std::atomic_flag occupied = ATOMIC_FLAG_INIT;
    auto owner = std::make_unique<forma::EngineLease>(occupied);
    bool excluded = false;
    std::thread contender([&] { try { forma::EngineLease duplicate(occupied); } catch (const std::runtime_error&) { excluded = true; } });
    contender.join(); assert(excluded);
    // The constructing thread and destroying thread intentionally differ.
    std::thread destroyer([lease = std::move(owner)]() mutable { lease.reset(); });
    destroyer.join();
    { forma::EngineLease next(occupied); }
    std::atomic<int> active{0}, successes{0}, collisions{0};
    std::atomic<bool> overlap{false};
    std::vector<std::thread> threads;
    for (int thread = 0; thread < 8; ++thread) threads.emplace_back([&] {
        for (int attempt = 0; attempt < 10000; ++attempt) {
            try {
                forma::EngineLease lease(occupied);
                if (active.fetch_add(1) != 0) overlap.store(true);
                std::this_thread::yield();
                active.fetch_sub(1); successes.fetch_add(1);
            } catch (const std::runtime_error&) { collisions.fetch_add(1); }
        }
    });
    for (auto& thread : threads) thread.join();
    assert(!overlap.load()); assert(active.load() == 0); assert(successes.load() > 0); assert(collisions.load() > 0);
    { forma::EngineLease afterFailures(occupied); }
    std::cout << "PASS: cross-thread destruction, competing constructor failure preserves owner, repeated contention excludes overlap, release permits next owner\n";
    std::cout << "successes=" << successes << " collisions=" << collisions << " overlap=false\n";
}
