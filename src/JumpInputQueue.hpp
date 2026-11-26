#pragma once

#define GOOSE_JUMP_PENDING_OFFSET 0
#define GOOSE_JUMP_IMPULSE_OFFSET 8
#define GOOSE_JUMP_CAP_ACTIVE_OFFSET 12
#define GOOSE_JUMP_LAST_MOVER_OFFSET 16
#define GOOSE_JUMP_TUNING_DATA_OFFSET 24
#define GOOSE_JUMP_ORIGINAL_CAP_OFFSET 32
#define GOOSE_JUMP_HOST_TIME_OFFSET 36
#define GOOSE_JUMP_QUEUE_TTL_SECONDS 0.5f
#define HONK_FLAGS_OFFSET 40
#define HONK_COMMAND_OFFSET 44
#define HONK_TARGET_X_OFFSET 48
#define HONK_TARGET_Y_OFFSET 52
#define HONK_TARGET_Z_OFFSET 56
#define HONK_SAVED_X_OFFSET 60
#define HONK_SAVED_Y_OFFSET 64
#define HONK_SAVED_Z_OFFSET 68
#define HONK_SPEED_FACTOR_OFFSET 72
#define HONK_SAVED_VALID_OFFSET 76
#define HONK_TIME_SCALE_OFFSET 80
#define HONK_SIZE_FACTOR_OFFSET 84
#define HONK_TIME_SCALE_ENABLED_OFFSET 88
#define HONK_HOVER_ENABLED_OFFSET 92
#define HONK_SCALE_CAPTURED_OFFSET 96
#define HONK_TIME_SCALE_APPLIED_OFFSET 100
#define HONK_SCALE_GOOSE_OFFSET 104
#define HONK_BASE_SCALE_X_OFFSET 112
#define HONK_BASE_SCALE_Y_OFFSET 116
#define HONK_BASE_SCALE_Z_OFFSET 120

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
    volatile uint32_t featureFlags;
    volatile uint32_t command;
    volatile uint32_t targetXBits;
    volatile uint32_t targetYBits;
    volatile uint32_t targetZBits;
    volatile uint32_t savedXBits;
    volatile uint32_t savedYBits;
    volatile uint32_t savedZBits;
    volatile uint32_t speedFactorBits;
    volatile uint32_t savedPositionValid;
    volatile uint32_t timeScaleBits;
    volatile uint32_t sizeFactorBits;
    volatile uint32_t timeScaleEnabled;
    volatile uint32_t hoverEnabled;
    volatile uint32_t scaleCaptured;
    volatile uint32_t timeScaleApplied;
    uintptr_t scaleGoose;
    float baseScaleX;
    float baseScaleY;
    float baseScaleZ;
} GooseJumpData;

static_assert(offsetof(GooseJumpData, pendingState) == GOOSE_JUMP_PENDING_OFFSET);
static_assert(offsetof(GooseJumpData, jumpImpulse) == GOOSE_JUMP_IMPULSE_OFFSET);
static_assert(offsetof(GooseJumpData, capOverrideActive) == GOOSE_JUMP_CAP_ACTIVE_OFFSET);
static_assert(offsetof(GooseJumpData, lastMover) == GOOSE_JUMP_LAST_MOVER_OFFSET);
static_assert(offsetof(GooseJumpData, tuningData) == GOOSE_JUMP_TUNING_DATA_OFFSET);
static_assert(offsetof(GooseJumpData, originalMaxUpwardVelocity) == GOOSE_JUMP_ORIGINAL_CAP_OFFSET);
static_assert(offsetof(GooseJumpData, hostTimeBits) == GOOSE_JUMP_HOST_TIME_OFFSET);
static_assert(offsetof(GooseJumpData, featureFlags) == HONK_FLAGS_OFFSET);
static_assert(offsetof(GooseJumpData, command) == HONK_COMMAND_OFFSET);
static_assert(offsetof(GooseJumpData, targetXBits) == HONK_TARGET_X_OFFSET);
static_assert(offsetof(GooseJumpData, targetYBits) == HONK_TARGET_Y_OFFSET);
static_assert(offsetof(GooseJumpData, targetZBits) == HONK_TARGET_Z_OFFSET);
static_assert(offsetof(GooseJumpData, savedXBits) == HONK_SAVED_X_OFFSET);
static_assert(offsetof(GooseJumpData, savedYBits) == HONK_SAVED_Y_OFFSET);
static_assert(offsetof(GooseJumpData, savedZBits) == HONK_SAVED_Z_OFFSET);
static_assert(offsetof(GooseJumpData, speedFactorBits) == HONK_SPEED_FACTOR_OFFSET);
static_assert(offsetof(GooseJumpData, savedPositionValid) == HONK_SAVED_VALID_OFFSET);
static_assert(offsetof(GooseJumpData, timeScaleBits) == HONK_TIME_SCALE_OFFSET);
static_assert(offsetof(GooseJumpData, sizeFactorBits) == HONK_SIZE_FACTOR_OFFSET);
static_assert(offsetof(GooseJumpData, hoverEnabled) == HONK_HOVER_ENABLED_OFFSET);
static_assert(offsetof(GooseJumpData, scaleCaptured) == HONK_SCALE_CAPTURED_OFFSET);
static_assert(offsetof(GooseJumpData, timeScaleEnabled) == HONK_TIME_SCALE_ENABLED_OFFSET);
static_assert(offsetof(GooseJumpData, timeScaleApplied) == HONK_TIME_SCALE_APPLIED_OFFSET);
static_assert(offsetof(GooseJumpData, scaleGoose) == HONK_SCALE_GOOSE_OFFSET);
static_assert(offsetof(GooseJumpData, baseScaleX) == HONK_BASE_SCALE_X_OFFSET);
static_assert(offsetof(GooseJumpData, baseScaleY) == HONK_BASE_SCALE_Y_OFFSET);
static_assert(offsetof(GooseJumpData, baseScaleZ) == HONK_BASE_SCALE_Z_OFFSET);

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

namespace HonkFeatures {

static constexpr uint32_t kJumpEnabled = 1u << 0;
static constexpr uint32_t kCommandNone = 0;
static constexpr uint32_t kCommandSavePosition = 1;
static constexpr uint32_t kCommandRestorePosition = 2;
static constexpr uint32_t kCommandTeleport = 3;
static constexpr uint32_t kFloatEnabled = 1u << 1;
static constexpr float kMinimumSpeedFactor = 0.5f;
static constexpr float kMaximumSpeedFactor = 3.0f;
static constexpr float kMinimumJumpImpulse = 0.5f;
static constexpr float kMaximumJumpImpulse = 12.0f;
static constexpr float kMaximumTeleportCoordinate = 100.0f;
static constexpr float kMinimumTimeScale = 0.5f;
static constexpr float kMaximumTimeScale = 2.0f;
static constexpr float kMinimumSizeFactor = 0.5f;
static constexpr float kMaximumSizeFactor = 2.0f;

inline bool finiteAndInRange(float value, float absoluteLimit) {
    return isfinite(value) && value >= -absoluteLimit && value <= absoluteLimit;
}

inline bool validTeleport(float x, float y, float z) {
    return finiteAndInRange(x, kMaximumTeleportCoordinate) &&
           finiteAndInRange(y, kMaximumTeleportCoordinate) &&
           finiteAndInRange(z, kMaximumTeleportCoordinate);
}

inline float boundedSpeedFactor(float value) {
    if (!isfinite(value)) return 1.0f;
    if (value < kMinimumSpeedFactor) return kMinimumSpeedFactor;
    if (value > kMaximumSpeedFactor) return kMaximumSpeedFactor;
    return value;
}

inline float boundedJumpImpulse(float value) {
    if (!isfinite(value)) return 2.5f;
    if (value < kMinimumJumpImpulse) return kMinimumJumpImpulse;
    if (value > kMaximumJumpImpulse) return kMaximumJumpImpulse;
    return value;
}

inline bool publishTeleport(GooseJumpData *state, float x, float y, float z) {
    if (!state || !validTeleport(x, y, z)) return false;
    __atomic_store_n(&state->targetXBits, GooseJumpInput::floatBits(x), __ATOMIC_RELAXED);
    __atomic_store_n(&state->targetYBits, GooseJumpInput::floatBits(y), __ATOMIC_RELAXED);
    __atomic_store_n(&state->targetZBits, GooseJumpInput::floatBits(z), __ATOMIC_RELAXED);
    __atomic_store_n(&state->command, kCommandTeleport, __ATOMIC_RELEASE);
    return true;
}

inline bool publishCommand(GooseJumpData *state, uint32_t command) {
    if (!state || command < kCommandSavePosition || command > kCommandTeleport) return false;
    __atomic_store_n(&state->command, command, __ATOMIC_RELEASE);
    return true;
}

inline bool hoverEnabled(const GooseJumpData *state) {
    return state && __atomic_load_n(&state->hoverEnabled, __ATOMIC_ACQUIRE) != 0;
}

inline void setHoverEnabled(GooseJumpData *state, bool enabled) {
    if (state) __atomic_store_n(&state->hoverEnabled, enabled ? 1u : 0u, __ATOMIC_RELEASE);
}

inline bool timeScaleEnabled(const GooseJumpData *state) {
    return state && __atomic_load_n(&state->timeScaleEnabled, __ATOMIC_ACQUIRE) != 0;
}

inline void setTimeScaleEnabled(GooseJumpData *state, bool enabled) {
    if (state) __atomic_store_n(&state->timeScaleEnabled, enabled ? 1u : 0u, __ATOMIC_RELEASE);
}

inline float boundedFactor(float value, float low, float high, float fallback) {
    if (!isfinite(value)) return fallback;
    if (value < low) return low;
    if (value > high) return high;
    return value;
}

inline float timeScale(const GooseJumpData *state) {
    if (!state) return 1.0f;
    return boundedFactor(GooseJumpInput::bitsFloat(__atomic_load_n(&state->timeScaleBits, __ATOMIC_ACQUIRE)),
                         kMinimumTimeScale, kMaximumTimeScale, 1.0f);
}

inline void setTimeScale(GooseJumpData *state, float value) {
    if (!state) return;
    const float bounded = boundedFactor(value, kMinimumTimeScale, kMaximumTimeScale, 1.0f);
    __atomic_store_n(&state->timeScaleBits, GooseJumpInput::floatBits(bounded), __ATOMIC_RELEASE);
}

inline float sizeFactor(const GooseJumpData *state) {
    if (!state) return 1.0f;
    return boundedFactor(GooseJumpInput::bitsFloat(__atomic_load_n(&state->sizeFactorBits, __ATOMIC_ACQUIRE)),
                         kMinimumSizeFactor, kMaximumSizeFactor, 1.0f);
}

inline void setSizeFactor(GooseJumpData *state, float value) {
    if (!state) return;
    const float bounded = boundedFactor(value, kMinimumSizeFactor, kMaximumSizeFactor, 1.0f);
    __atomic_store_n(&state->sizeFactorBits, GooseJumpInput::floatBits(bounded), __ATOMIC_RELEASE);
}

} // namespace HonkFeatures
#endif
