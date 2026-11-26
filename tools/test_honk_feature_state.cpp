#include "../src/HonkFeatureState.hpp"
#include <cassert>
#include <cmath>
#include <cstdint>

int main() {
    static_assert(sizeof(GooseJumpData) == 1472);
    GooseJumpData state{};
    assert(!HonkFeatures::jumpEnabled(&state));
    HonkFeatures::setJumpEnabled(&state, true);
    assert(HonkFeatures::jumpEnabled(&state));
    HonkFeatures::setJumpEnabled(&state, false);
    assert(!HonkFeatures::jumpEnabled(&state));

    assert(!HonkFeatures::hoverEnabled(&state));
    HonkFeatures::setHoverEnabled(&state, true);
    assert(HonkFeatures::hoverEnabled(&state));
    HonkFeatures::setHoverEnabled(&state, false);
    assert(!HonkFeatures::hoverEnabled(&state));
    assert(!HonkFeatures::disableNpcShoo(&state));
    HonkFeatures::setDisableNpcShoo(&state, true);
    assert(HonkFeatures::disableNpcShoo(&state));
    HonkFeatures::setDisableNpcShoo(&state, false);
    assert(!HonkFeatures::disableNpcShoo(&state));

    HonkFeatures::setTimeScale(&state, 1.25f);
    assert(std::fabs(HonkFeatures::timeScale(&state) - 1.25f) < 0.0001f);
    HonkFeatures::setTimeScale(&state, 0.0f);
    assert(std::fabs(HonkFeatures::timeScale(&state) - HonkFeatures::kMinimumTimeScale) < 0.0001f);
    HonkFeatures::setTimeScale(&state, 7.0f);
    assert(std::fabs(HonkFeatures::timeScale(&state) - HonkFeatures::kMaximumTimeScale) < 0.0001f);
    HonkFeatures::setTimeScale(&state, NAN);
    assert(std::fabs(HonkFeatures::timeScale(&state) - 1.0f) < 0.0001f);
    HonkFeatures::setTimeScaleEnabled(&state, true);
    assert(HonkFeatures::timeScaleEnabled(&state));

    HonkFeatures::setSizeFactor(&state, 1.5f);
    assert(std::fabs(HonkFeatures::sizeFactor(&state) - 1.5f) < 0.0001f);
    HonkFeatures::setSizeFactor(&state, 0.1f);
    assert(std::fabs(HonkFeatures::sizeFactor(&state) - HonkFeatures::kMinimumSizeFactor) < 0.0001f);
    HonkFeatures::setSizeFactor(&state, 4.0f);
    assert(std::fabs(HonkFeatures::sizeFactor(&state) - HonkFeatures::kMaximumSizeFactor) < 0.0001f);
    HonkFeatures::setSizeFactor(&state, INFINITY);
    assert(std::fabs(HonkFeatures::sizeFactor(&state) - 1.0f) < 0.0001f);
    HonkFeatures::setCameraFactor(&state, 1.5f);
    assert(std::fabs(HonkFeatures::cameraFactor(&state) - 1.5f) < 0.0001f);
    HonkFeatures::setCameraFactor(&state, 8.0f);
    assert(std::fabs(HonkFeatures::cameraFactor(&state) - HonkFeatures::kMaximumCameraFactor) < 0.0001f);
    HonkFeatures::setNpcSizeFactor(&state, 1.5f);
    assert(std::fabs(HonkFeatures::npcSizeFactor(&state) - 1.5f) < 0.0001f);
    HonkFeatures::setNpcSizeFactor(&state, 10.0f);
    assert(std::fabs(HonkFeatures::npcSizeFactor(&state) - HonkFeatures::kMaximumNpcSizeFactor) < 0.0001f);
    HonkFeatures::setNpcSizeFactor(&state, NAN);
    assert(std::fabs(HonkFeatures::npcSizeFactor(&state) - 1.0f) < 0.0001f);
    assert(!HonkFeatures::npcTrackingEnabled(&state));
    HonkFeatures::setNpcTrackingEnabled(&state, true);
    assert(HonkFeatures::npcTrackingEnabled(&state));
    HonkFeatures::setNpcTrackingEnabled(&state, false);
    assert(!HonkFeatures::npcTrackingEnabled(&state));

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
    for (uint32_t command = HonkFeatures::kCommandCreateSphere;
         command <= HonkFeatures::kCommandCreateCube; ++command) {
        assert(HonkFeatures::publishCommand(&state, command));
        assert(__atomic_load_n(&state.command, __ATOMIC_ACQUIRE) == command);
    }
    assert(HonkFeatures::publishCommand(&state, HonkFeatures::kCommandDestroySpawned));
    assert(__atomic_load_n(&state.command, __ATOMIC_ACQUIRE) == HonkFeatures::kCommandDestroySpawned);
    assert(HonkFeatures::publishCommand(&state, HonkFeatures::kCommandTeleportToCamera));
    assert(__atomic_load_n(&state.command, __ATOMIC_ACQUIRE) == HonkFeatures::kCommandTeleportToCamera);
    assert(!HonkFeatures::publishCommand(&state, HonkFeatures::kCommandTeleportToCamera + 1));
}
