#pragma once

#include "JumpInputQueue.hpp"

namespace HonkFeatures {

inline uint32_t flags(const GooseJumpData *state) {
    return state ? __atomic_load_n(&state->featureFlags, __ATOMIC_ACQUIRE) : 0;
}

inline bool jumpEnabled(const GooseJumpData *state) {
    return (flags(state) & kJumpEnabled) != 0;
}

inline void setJumpEnabled(GooseJumpData *state, bool enabled) {
    if (!state) return;
    uint32_t observed = __atomic_load_n(&state->featureFlags, __ATOMIC_ACQUIRE);
    uint32_t desired;
    do {
        desired = enabled ? (observed | kJumpEnabled) : (observed & ~kJumpEnabled);
    } while (!__atomic_compare_exchange_n(&state->featureFlags, &observed, desired,
                                           true, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE));
}

inline float speedFactor(const GooseJumpData *state) {
    if (!state) return 1.0f;
    const uint32_t bits = __atomic_load_n(&state->speedFactorBits, __ATOMIC_ACQUIRE);
    return boundedSpeedFactor(GooseJumpInput::bitsFloat(bits));
}

inline void setSpeedFactor(GooseJumpData *state, float value) {
    if (!state) return;
    const float bounded = boundedSpeedFactor(value);
    __atomic_store_n(&state->speedFactorBits, GooseJumpInput::floatBits(bounded),
                     __ATOMIC_RELEASE);
}

inline void setJumpImpulse(GooseJumpData *state, float value) {
    if (!state) return;
    const float bounded = boundedJumpImpulse(value);
    auto *bits = reinterpret_cast<volatile uint32_t *>(&state->jumpImpulse);
    __atomic_store_n(bits, GooseJumpInput::floatBits(bounded), __ATOMIC_RELEASE);
}

} // namespace HonkFeatures
