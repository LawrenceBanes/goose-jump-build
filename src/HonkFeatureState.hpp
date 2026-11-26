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

inline bool freeCameraEnabled(const GooseJumpData *state) {
    return (flags(state) & kFreeCamera) != 0;
}

inline bool firstPersonCameraEnabled(const GooseJumpData *state) {
    return (flags(state) & kFirstPersonCamera) != 0;
}

inline void setFirstPersonCameraEnabled(GooseJumpData *state, bool enabled) {
    if (!state) return;
    uint32_t observed = __atomic_load_n(&state->featureFlags, __ATOMIC_ACQUIRE);
    uint32_t desired;
    do {
        desired = enabled ? ((observed | kFirstPersonCamera) & ~kFreeCamera)
                          : (observed & ~kFirstPersonCamera);
    } while (!__atomic_compare_exchange_n(&state->featureFlags, &observed, desired,
                                           true, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE));
}

inline bool setFreeCameraEnabled(GooseJumpData *state, bool enabled) {
    if (!state) return false;
    if (enabled) {
        if (!__atomic_load_n(&state->cameraPositionValid, __ATOMIC_ACQUIRE)) return false;
        const float x = GooseJumpInput::bitsFloat(
            __atomic_load_n(&state->cameraPositionXBits, __ATOMIC_ACQUIRE));
        const float y = GooseJumpInput::bitsFloat(
            __atomic_load_n(&state->cameraPositionYBits, __ATOMIC_ACQUIRE));
        const float z = GooseJumpInput::bitsFloat(
            __atomic_load_n(&state->cameraPositionZBits, __ATOMIC_ACQUIRE));
        if (!validTeleport(x, y, z)) return false;
        __atomic_store_n(&state->freeCameraXBits, GooseJumpInput::floatBits(x), __ATOMIC_RELAXED);
        __atomic_store_n(&state->freeCameraYBits, GooseJumpInput::floatBits(y), __ATOMIC_RELAXED);
        __atomic_store_n(&state->freeCameraZBits, GooseJumpInput::floatBits(z), __ATOMIC_RELAXED);
    }
    uint32_t observed = __atomic_load_n(&state->featureFlags, __ATOMIC_ACQUIRE);
    uint32_t desired;
    do {
        desired = enabled ? ((observed | kFreeCamera) & ~kFirstPersonCamera)
                          : (observed & ~kFreeCamera);
    } while (!__atomic_compare_exchange_n(&state->featureFlags, &observed, desired,
                                           true, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE));
    return true;
}

inline bool nudgeFreeCamera(GooseJumpData *state, float dx, float dy, float dz) {
    if (!state || !freeCameraEnabled(state) ||
        !isfinite(dx) || !isfinite(dy) || !isfinite(dz)) return false;
    const float x = GooseJumpInput::bitsFloat(
        __atomic_load_n(&state->freeCameraXBits, __ATOMIC_ACQUIRE)) + dx;
    const float y = GooseJumpInput::bitsFloat(
        __atomic_load_n(&state->freeCameraYBits, __ATOMIC_ACQUIRE)) + dy;
    const float z = GooseJumpInput::bitsFloat(
        __atomic_load_n(&state->freeCameraZBits, __ATOMIC_ACQUIRE)) + dz;
    if (!validTeleport(x, y, z)) return false;
    __atomic_store_n(&state->freeCameraXBits, GooseJumpInput::floatBits(x), __ATOMIC_RELEASE);
    __atomic_store_n(&state->freeCameraYBits, GooseJumpInput::floatBits(y), __ATOMIC_RELEASE);
    __atomic_store_n(&state->freeCameraZBits, GooseJumpInput::floatBits(z), __ATOMIC_RELEASE);
    return true;
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
