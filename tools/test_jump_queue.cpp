#include "../src/JumpInputQueue.hpp"

#include <cassert>
#include <thread>
#include <vector>

int main() {
    volatile uint64_t pending = 0;
    constexpr unsigned producers = 8;
    constexpr unsigned tapsPerProducer = 5000;
    std::vector<std::thread> threads;
    for (unsigned p = 0; p < producers; ++p) {
        threads.emplace_back([&pending] {
            for (unsigned i = 0; i < tapsPerProducer; ++i)
                assert(GooseJumpInput::enqueue(&pending, 42.0f));
        });
    }
    for (auto &thread : threads) thread.join();
    assert(GooseJumpInput::pendingCount(__atomic_load_n(&pending, __ATOMIC_ACQUIRE)) ==
           producers * tapsPerProducer);

    // One physics consumption per fixed update preserves every distinct tap.
    uint64_t event = 0;
    unsigned consumed = 0;
    while (GooseJumpInput::consumeOne(&pending, 42.1f, &event)) ++consumed;
    assert(consumed == producers * tapsPerProducer);
    assert(GooseJumpInput::pendingCount(__atomic_load_n(&pending, __ATOMIC_ACQUIRE)) == 0);

    assert(GooseJumpInput::enqueue(&pending, 10.0f));
    bool stale = false;
    assert(!GooseJumpInput::consumeOne(&pending, 11.0f, &event, &stale));
    assert(stale);
    assert(GooseJumpInput::pendingCount(__atomic_load_n(&pending, __ATOMIC_ACQUIRE)) == 0);

    assert(GooseJumpInput::enqueue(&pending, 20.0f));
    GooseJumpInput::clear(&pending);
    assert(GooseJumpInput::pendingCount(__atomic_load_n(&pending, __ATOMIC_ACQUIRE)) == 0);
}
