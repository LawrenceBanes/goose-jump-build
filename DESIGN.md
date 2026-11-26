# Jump modification design

## Chosen path

Use a version-pinned static ARM64 call-site patch in `Mover.FixedUpdate`, plus a small embedded UIKit dylib for the on-screen button. The patch calls a helper placed in a newly declared `__TEXT,__goose` section inside the existing executable segment's verified padding. The helper runs after the game's horizontal velocity setter, checks a one-shot request and grounded/state guards, then writes only `Rigidbody.velocity.y`. The dylib owns the UI and writes the one-shot request into a newly declared zero-fill `__DATA,__goose` section. No runtime code page is made writable and no instruction trampoline relocates displaced PC-relative instructions.

This reuses the game's physics and leaves the game's horizontal velocity assignment intact. A UIKit button is the practical input bridge because the executable exports no IL2CPP C API; the existing virtual-button path would require adding a managed object/reference and extending game-side input state. The button will be anchored to the native Unity view's safe area and will not intercept touches outside its own bounds.

## Verified movement data flow

Il2CppDumper v6.7.46 accepted the executable and a temporary metadata copy with only the first four bytes restored. It identified IL2CPP 24.1, `CodeRegistration` RVA `0x270e660`, and `MetadataRegistration` RVA `0x279fa58`. Its method map resolves:

- `Mover.FixedUpdate`: RVA `0x1110618`, preferred VA `0x101110618`, end `0x101110b50`.
- `Mover` fields: `goose` at object offset `0x10`, `rb` at `0x18`.
- The old lead `0x1011107e0` is the call to `Rigidbody.set_velocity`, not a function entry. The next instruction at `0x1011107e4` is `ldr x20, [x19, #16]` (load the Goose reference); the patch will replace this one instruction with `BL helper`, and the helper will execute that load before returning. The original function's stack frame, saved registers, and remaining instructions stay in place.
- Immediately before the setter, the method computes new horizontal X/Z velocity from `Transform.forward * currentSpeed` and carries the prior Rigidbody Y velocity into the setter. This confirms the hook point can add vertical velocity after horizontal movement has been assigned.
- `Goose.FixedUpdate` calls `Mover.FixedUpdate` and later performs another Rigidbody velocity write. That later code applies `Mathf.Min(currentY, tuningData.maxUpwardVelocity)`. The helper will clamp configured jump strength to `GooseTuningData.maxUpwardVelocity`, so this existing write preserves the upward impulse while retaining the game's cap.

## Ground and state guards

The dump gives `Goose.gooseGround` at `Goose + 0xb0`, `Goose.isSwimming` at `+0x250`, `Goose.dragger` at `+0x58`, and `Goose.tuningData` at `+0x20`. `GooseGround` is a value type with `alwaysGrounded` at `+0x55`, `staticCollisionCount` at `+0x58`, and `propCollisions` at `+0x60`. Collision-enter/exit disassembly increments/decrements `staticCollisionCount` only for layers accepted by `staticGroundLayers`; it also maintains the prop collision list. The helper accepts `alwaysGrounded`, a positive static ground collision count, or a nonempty prop collision list, and also requires nonpositive vertical velocity and an airborne latch. After takeoff, it requires two successive physics updates reporting contact and nonpositive Y velocity before clearing the latch. This check runs even when there is no pending tap, so waiting until after landing does not require an extra tap.

The helper rejects swimming (`Goose.isSwimming` and embedded `GooseSwimmer.isSwimming`), an active `Dragger` interaction, and a kinematic Rigidbody. Both the UIKit callback and physics helper check `Time.timeScale`. App backgrounding clears pending requests. A 0.5-second request expiry prevents a tap in a menu/transition from becoming a jump after a later scene load. The airborne latch is reset only after two grounded physics observations with nonpositive Y velocity; rearming runs even when no jump request is pending.

## UI and data storage

The native Jump button is attached to the `UnityAppController` window's root view, retried during startup and root replacement, and anchored in the safe area (with layout margins on pre-iOS 11). It does not fall back to LiveContainer's host key window. The callback publishes a timestamp then a request with release ordering; the physics helper consumes it with acquire ordering in `FixedUpdate`. Strength and cooldown are build-time options written into the new data section. Cooldown uses `Time.fixedDeltaTime` and an elapsed timer. The helper resets state when the Mover instance changes and retains no managed-object cache.

`__DATA` currently ends at preferred VA `0x102e1c000`; its `__common` section ends at `0x102ddd250`. The final page `0x102e1b000..0x102e1c000` is inside the existing writable segment, outside every declared section, and not file-backed. The patcher explicitly declares that page as a new zero-fill section. The code helper declares its section over the verified padding beginning at file offset `0x26f0c20`, after `__eh_frame` ends at `0x26f0c1c`. Both are statically checked for overlap before patching.

## Safety limits

The patch applies only to the pinned original IPA/executable/metadata hashes and verifies the metadata version, expected instruction bytes, Mach-O sections, target function interval, helper relocation locations, and `BL` range. The helper uses caller-saved scratch registers and a small aligned local frame; it preserves the Goose pointer in the callee-saved register expected by the following original instruction and leaves the enclosing Mover frame intact. Its direct calls are version-pinned to the resolved Rigidbody/Time method RVAs. It does not call `mprotect`, allocate executable memory, or alter the original IPA.

This design is supported by static evidence but is not an iPhone runtime result. LiveContainer import/JIT behavior, UIKit overlay placement, collision behavior on slopes/props, pause behavior, and actual takeoff/landing still require a packaged build and device test. If the helper cannot fit in the declared code padding or the reconstructed `GooseGround` conditions fail static checks, the patcher must stop without emitting an IPA.

## LiveContainer compatibility

LiveContainer rewrites the guest `MH_EXECUTE` to `MH_DYLIB`, adjusts `__PAGEZERO`, injects its TweakLoader, and redirects `@executable_path` to the guest bundle. The Jump dependency and dylib ID both use `@executable_path/Frameworks/GooseJump.dylib`. The patch preserves the main executable `LC_UUID` (`8c9e468f0d5439e5864f176491607698`); the overlay scans dyld images for that UUID and computes data/function pointers from that image's slide. The call-site BL, helper BLs, and ADRP reference are intra-image or slide-relative and remain coherent under ASLR.

JIT does not remove Mach-O validity, UUID matching, dependency resolution, UIKit window ownership, or ABI requirements. LiveContainer's JIT bypasses code-signature/library validation only where its runtime and iOS version support that path. The IPA is packaged unsigned and the build does not invoke a standalone signing workflow.

## Mission 05 / v0.2.0 changes

This section supersedes earlier grounded-only/cooldown statements above. Every distinct rounded-button touch-down is now a jump request, including while airborne. The ARM64 helper consumes one request per physics update and sets `velocity.y` to `max(currentY, 0) + 2.5`; it preserves the getter's X/Z components. A saturating 31-bit count is packed with the latest monotonic timestamp in one aligned 64-bit atomic word, so rapid touches are not collapsed into a boolean. Requests older than 0.5 seconds are discarded and lifecycle interruptions clear the queue. UIKit never calls Unity physics; the helper consumes requests on the existing `Mover.FixedUpdate` thread.

The prior effective launch velocity was 1.5 Unity units/s because `Goose.FixedUpdate` clamps it through `GooseTuningData.maxUpwardVelocity`. The new default launch increment is 2.5 units/s. During ascent the helper temporarily raises that serialized runtime cap to the observed upward velocity, follows the gravity-reduced velocity each physics tick, then restores the original cap when the goose falls below it or enters an incompatible state. Under constant gravity, the expected first-jump height ratio is approximately `(2.5 / 1.5)^2 = 2.78`; this is an estimate, not device measurement. There is no grounded check, jump-count limit, cooldown, or altitude cap.

The overlay is a button-sized sibling of the Unity root, not a fullscreen touch shield. Its custom rounded hit test captures only the visible button region; all ancestor/surface views are configured for multitouch and nonexclusive touch. Touch-down enqueues once; holding and touch cancellation do not repeat. UIKit hierarchy behavior, joystick+Jump concurrency, air-jump feel, and pause/scene behavior still require physical-device verification.

## Honk-Menu native features

The physics helper remains the single Unity call dispatcher. The native menu publishes atomics for hover and scale values and an optional Time.timeScale override; it does not invoke Unity from UIKit. Float mode zeroes only vertical velocity, preserves horizontal movement and leaves all colliders enabled. Goose scale is always calculated from a per-Goose captured baseline. Game-speed changes are bounded to 0.5×–2×, applied only when Time.timeScale is already positive, and return to 1× when the override is disabled. True noclip, camera, NPC, item creation, and progression controls stay unavailable until exact APIs and state restoration are verified.
