#include "../src/HonkFeatureState.hpp"
#include <cassert>
#include <cmath>
#include <cstdint>

int main() {
    static_assert(sizeof(GooseJumpData) == 80);
    GooseJumpData state{};
    assert(!HonkFeatures::jumpEnabled(&state));
    HonkFeatures::setJumpEnabled(&state, true);
    assert(HonkFeatures::jumpEnabled(&state));
    HonkFeatures::setJumpEnabled(&state, false);
    assert(!HonkFeatures::jumpEnabled(&state));

    HonkFeatures::setSpeedFactor(&state, 1.75f);
    assert(std::fabs(HonkFeatures::speedFactor(&state) - 1.75f) < 0.0001f);
    HonkFeatures::setSpeedFactor(&state, -50.0f);
    assert(std::fabs(HonkFeatures::speedFactor(&state) - HonkFeatures::kMinimumSpeedFactor) < 0.0001f);
    HonkFeatures::setSpeedFactor(&state, 500.0f);
    assert(std::fabs(HonkFeatures::speedFactor(&state) - HonkFeatures::kMaximumSpeedFactor) < 0.0001f);
    HonkFeatures::setSpeedFactor(&state, NAN);
    assert(std::fabs(HonkFeatures::speedFactor(&state) - 1.0f) < 0.0001f);

    HonkFeatures::setJumpImpulse(&state, 4.25f);
    auto *impulseBits = reinterpret_cast<volatile uint32_t *>(&state.jumpImpulse);
    assert(std::fabs(GooseJumpInput::bitsFloat(__atomic_load_n(impulseBits, __ATOMIC_ACQUIRE)) - 4.25f) < 0.0001f);
    HonkFeatures::setJumpImpulse(&state, INFINITY);
    assert(std::fabs(GooseJumpInput::bitsFloat(__atomic_load_n(impulseBits, __ATOMIC_ACQUIRE)) - 2.5f) < 0.0001f);

    assert(HonkFeatures::validTeleport(-54.1f, 1.6f, 1.5f));
    assert(!HonkFeatures::validTeleport(NAN, 0, 0));
    assert(!HonkFeatures::validTeleport(0, INFINITY, 0));
    assert(!HonkFeatures::validTeleport(100.01f, 0, 0));
    assert(HonkFeatures::publishTeleport(&state, -23.3f, 1.3f, 2.2f));
    assert(GooseJumpInput::bitsFloat(__atomic_load_n(&state.targetXBits, __ATOMIC_ACQUIRE)) == -23.3f);
    assert(GooseJumpInput::bitsFloat(__atomic_load_n(&state.targetYBits, __ATOMIC_ACQUIRE)) == 1.3f);
    assert(GooseJumpInput::bitsFloat(__atomic_load_n(&state.targetZBits, __ATOMIC_ACQUIRE)) == 2.2f);
    assert(__atomic_load_n(&state.command, __ATOMIC_ACQUIRE) == HonkFeatures::kCommandTeleport);
    assert(!HonkFeatures::publishTeleport(&state, NAN, 0, 0));
    assert(!HonkFeatures::publishCommand(&state, 0));
    assert(HonkFeatures::publishCommand(&state, HonkFeatures::kCommandSavePosition));
    assert(__atomic_load_n(&state.command, __ATOMIC_ACQUIRE) == HonkFeatures::kCommandSavePosition);
}
