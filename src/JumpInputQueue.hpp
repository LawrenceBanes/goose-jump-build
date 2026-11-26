#pragma once

#define GOOSE_JUMP_PENDING_OFFSET 0
#define GOOSE_JUMP_IMPULSE_OFFSET 8
#define GOOSE_JUMP_CAP_ACTIVE_OFFSET 12
#define GOOSE_JUMP_LAST_MOVER_OFFSET 16
#define GOOSE_JUMP_TUNING_DATA_OFFSET 24
#define GOOSE_JUMP_ORIGINAL_CAP_OFFSET 32
#define GOOSE_JUMP_HOST_TIME_OFFSET 36
#define GOOSE_JUMP_QUEUE_TTL_SECONDS 0.5f

#ifndef __ASSEMBLER__
#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

typedef struct GooseJumpData {
    volatile uint64_t pendingState; // upper word: touch timestamp bits; lower word: event count
    float jumpImpulse;
    volatile uint32_t capOverrideActive;
    uintptr_t lastMover;
    uintptr_t tuningData;
    float originalMaxUpwardVelocity;
    volatile uint32_t hostTimeBits;
} GooseJumpData;

static_assert(offsetof(GooseJumpData, pendingState) == GOOSE_JUMP_PENDING_OFFSET);
static_assert(offsetof(GooseJumpData, jumpImpulse) == GOOSE_JUMP_IMPULSE_OFFSET);
static_assert(offsetof(GooseJumpData, capOverrideActive) == GOOSE_JUMP_CAP_ACTIVE_OFFSET);
static_assert(offsetof(GooseJumpData, lastMover) == GOOSE_JUMP_LAST_MOVER_OFFSET);
static_assert(offsetof(GooseJumpData, tuningData) == GOOSE_JUMP_TUNING_DATA_OFFSET);
static_assert(offsetof(GooseJumpData, originalMaxUpwardVelocity) == GOOSE_JUMP_ORIGINAL_CAP_OFFSET);
static_assert(offsetof(GooseJumpData, hostTimeBits) == GOOSE_JUMP_HOST_TIME_OFFSET);

namespace GooseJumpInput {

static constexpr uint32_t kMaximumPendingEvents = 0x7fffffffU;

inline uint32_t floatBits(float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

inline float bitsFloat(uint32_t bits) {
    float value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

inline uint32_t pendingCount(uint64_t state) {
    return static_cast<uint32_t>(state);
}

// One UIKit touch-down publishes exactly one event. The 64-bit CAS keeps the
// count and timestamp coherent while the physics consumer runs independently.
inline bool enqueue(volatile uint64_t *state, float timestamp) {
    const uint64_t timestampWord = static_cast<uint64_t>(floatBits(timestamp)) << 32;
    uint64_t observed = __atomic_load_n(state, __ATOMIC_ACQUIRE);
    for (;;) {
        const uint32_t count = pendingCount(observed);
        if (count >= kMaximumPendingEvents) return false;
        const uint64_t desired = timestampWord | static_cast<uint64_t>(count + 1);
        if (__atomic_compare_exchange_n(state, &observed, desired, true,
                                        __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
            return true;
        }
    }
}

// Portable reference implementation used by native regression tests. The
// production physics consumer performs the same compare/exchange in ARM64.
inline bool consumeOne(volatile uint64_t *state, float now, uint64_t *event,
                       bool *wasStale = nullptr) {
    uint64_t observed = __atomic_load_n(state, __ATOMIC_ACQUIRE);
    while (pendingCount(observed) != 0) {
        const float timestamp = bitsFloat(static_cast<uint32_t>(observed >> 32));
        const bool stale = !isfinite(timestamp) || !isfinite(now) ||
                           (now - timestamp > GOOSE_JUMP_QUEUE_TTL_SECONDS) ||
                           (timestamp - now > GOOSE_JUMP_QUEUE_TTL_SECONDS);
        const uint64_t desired = stale ? 0 : observed - 1;
        if (__atomic_compare_exchange_n(state, &observed, desired, true,
                                        __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
            if (event) *event = observed;
            if (wasStale) *wasStale = stale;
            return !stale;
        }
    }
    if (wasStale) *wasStale = false;
    return false;
}

inline void clear(volatile uint64_t *state) {
    __atomic_store_n(state, 0, __ATOMIC_RELEASE);
}

} // namespace GooseJumpInput
#endif
