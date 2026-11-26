/* ARM64 helper called from Mover.FixedUpdate after Rigidbody.set_velocity.
 * It replays the displaced ldr x20,[x19,#16], consumes one queued touch-down,
 * and writes only Rigidbody velocity.y. See JumpInputQueue.hpp for shared
 * data offsets and the packed atomic request format.
 */

#include "JumpInputQueue.hpp"

.text
.p2align 2
.global goose_jump_helper
.type goose_jump_helper, %function

goose_jump_helper:
    sub     sp, sp, #48
    str     x22, [sp, #32]
    str     x30, [sp, #40]
    ldr     x20, [x19, #16]          // displaced original instruction

goose_reloc_data_adrp:
    .inst   0x90000016              // ADRP x22, goose_jump_data
goose_reloc_data_add:
    .inst   0x910002d6              // ADD x22, x22, #lo12(goose_jump_data)

    // A new Mover marks a scene/player replacement; never carry its queued
    // input or temporary tuning cap into the new instance.
    ldr     x9, [x22, #GOOSE_JUMP_LAST_MOVER_OFFSET]
    cmp     x9, x19
    b.eq    .Lsame_mover
    ldr     w10, [x22, #GOOSE_JUMP_CAP_ACTIVE_OFFSET]
    cbz     w10, .Lreset_state
    ldr     x11, [x22, #GOOSE_JUMP_TUNING_DATA_OFFSET]
    cbz     x11, .Lreset_state
    ldr     s0, [x22, #GOOSE_JUMP_ORIGINAL_CAP_OFFSET]
    str     s0, [x11, #0x18]         // restore GooseTuningData.maxUpwardVelocity
.Lreset_state:
    stlr    xzr, [x22, #GOOSE_JUMP_PENDING_OFFSET]
    str     wzr, [x22, #GOOSE_JUMP_CAP_ACTIVE_OFFSET]
    str     xzr, [x22, #GOOSE_JUMP_TUNING_DATA_OFFSET]
    add     x10, x22, #HONK_COMMAND_OFFSET
    stlr    wzr, [x10]
    add     x10, x22, #HONK_SAVED_VALID_OFFSET
    stlr    wzr, [x10]
    add     x10, x22, #HONK_FLAGS_OFFSET
    ldar    w11, [x10]
    bic     w11, w11, #48           // clear free-camera and first-person modes
    stlr    w11, [x10]
    str     xzr, [x22, #HONK_SPAWNED_OBJECT_OFFSET]
    str     wzr, [x22, #HONK_SCALE_CAPTURED_OFFSET]
    str     xzr, [x22, #HONK_SCALE_GOOSE_OFFSET]
    str     wzr, [x22, #HONK_CAMERA_CAPTURED_OFFSET]
    str     xzr, [x22, #HONK_CAMERA_HELPER_OFFSET]
    str     wzr, [x22, #HONK_RENDERER_COLOR_COUNT_OFFSET]
    add     x10, x22, #HONK_CAMERA_POSITION_VALID_OFFSET
    stlr    wzr, [x10]
    add     x9, x22, #HONK_NPC_SCALE_TABLE_OFFSET
    mov     w10, #HONK_NPC_SCALE_ENTRY_COUNT
.Lreset_npc_scale_entries:
    stlr    xzr, [x9]
    add     x9, x9, #HONK_NPC_SCALE_ENTRY_SIZE
    subs    w10, w10, #1
    b.ne    .Lreset_npc_scale_entries
    str     x19, [x22, #GOOSE_JUMP_LAST_MOVER_OFFSET]
.Lsame_mover:
    // Apply the UI speed multiplier to the horizontal velocity computed by
    // the original Mover.FixedUpdate. The game recomputes that velocity on
    // every call, so this does not compound across physics ticks.
    add     x10, x22, #HONK_SPEED_FACTOR_OFFSET
    ldar    w10, [x10]
    fmov    s4, w10
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lprocess_command
    fmov    s3, #1.0
    fcmp    s4, s3
    b.eq    .Lprocess_command
    fmov    s3, #0.5
    fcmp    s4, s3
    b.lt    .Lprocess_command
    fmov    s3, #3.0
    fcmp    s4, s3
    b.gt    .Lprocess_command
    ldr     x9, [x19, #0x18]
    cbz     x9, .Lprocess_command
    mov     x0, x9
    mov     x1, xzr
goose_reloc_speed_get_velocity:
    .inst   0x94000000              // BL Rigidbody.get_velocity
    fmov    w10, s0
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lprocess_command
    fmov    w10, s2
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lprocess_command
    add     x10, x22, #HONK_SPEED_FACTOR_OFFSET
    ldar    w10, [x10]
    fmov    s3, w10
    fmul    s0, s0, s3
    fmul    s2, s2, s3
    fmov    w10, s0
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lprocess_command
    fmov    w10, s2
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lprocess_command
    str     s0, [sp, #0]
    str     s1, [sp, #4]
    str     s2, [sp, #8]
    ldr     x0, [x19, #0x18]
    ldr     s0, [sp, #0]
    ldr     s1, [sp, #4]
    ldr     s2, [sp, #8]
    mov     x1, xzr
goose_reloc_speed_set_velocity:
    .inst   0x94000000              // BL Rigidbody.set_velocity

.Lprocess_command:
    // Game-thread work is serialized here. UIKit only publishes a bounded
    // command and coordinates; it never calls into Unity from the main thread.
    add     x10, x22, #HONK_COMMAND_OFFSET
    ldar    w9, [x10]
    cbz     w9, .Lafter_command
    mov     x0, xzr
goose_reloc_command_time_scale:
    .inst   0x94000000              // BL UnityEngine.Time.get_timeScale
    fmov    s1, wzr
    fcmp    s0, s1
    b.le    .Lafter_command         // keep the request pending while paused
    add     x10, x22, #HONK_COMMAND_OFFSET
    ldar    w9, [x10]
    cbz     w9, .Lafter_command
    stlr    wzr, [x10]
    cmp     w9, #1
    b.eq    .Lsave_position
    cmp     w9, #2
    b.eq    .Lrestore_position
    cmp     w9, #3
    b.eq    .Lteleport_position
    cmp     w9, #4
    b.lo    .Lafter_command
    cmp     w9, #7
    b.ls    .Lspawn_primitive
    cmp     w9, #8
    b.eq    .Ldestroy_spawned
    cmp     w9, #9
    b.eq    .Lteleport_to_camera
    b       .Lafter_command

.Lteleport_to_camera:
    add     x10, x22, #HONK_CAMERA_POSITION_VALID_OFFSET
    ldar    w10, [x10]
    cbz     w10, .Lafter_command
    add     x10, x22, #HONK_CAMERA_POSITION_X_OFFSET
    ldar    w10, [x10]
    fmov    s0, w10
    add     x10, x22, #HONK_CAMERA_POSITION_Y_OFFSET
    ldar    w10, [x10]
    fmov    s1, w10
    add     x10, x22, #HONK_CAMERA_POSITION_Z_OFFSET
    ldar    w10, [x10]
    fmov    s2, w10
    fmov    w10, s0
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lafter_command
    fmov    w10, s1
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lafter_command
    fmov    w10, s2
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lafter_command
    mov     w10, #100
    scvtf   s3, w10
    fabs    s4, s0
    fcmp    s4, s3
    b.gt    .Lafter_command
    fabs    s4, s1
    fcmp    s4, s3
    b.gt    .Lafter_command
    fabs    s4, s2
    fcmp    s4, s3
    b.gt    .Lafter_command
    b       .Lmove_to_position

.Lsave_position:
    ldr     x0, [x19, #0x18]
    cbz     x0, .Lafter_command
    mov     x1, xzr
goose_reloc_get_position:
    .inst   0x94000000              // BL Rigidbody.get_position
    // Store only finite coordinates; the later restore is also validated.
    fmov    w10, s0
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lafter_command
    fmov    w10, s1
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lafter_command
    fmov    w10, s2
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lafter_command
    mov     w10, #100
    scvtf   s3, w10
    fabs    s4, s0
    fcmp    s4, s3
    b.gt    .Lafter_command
    fabs    s4, s1
    fcmp    s4, s3
    b.gt    .Lafter_command
    fabs    s4, s2
    fcmp    s4, s3
    b.gt    .Lafter_command
    str     s0, [x22, #HONK_SAVED_X_OFFSET]
    str     s1, [x22, #HONK_SAVED_Y_OFFSET]
    str     s2, [x22, #HONK_SAVED_Z_OFFSET]
    mov     w10, #1
    add     x11, x22, #HONK_SAVED_VALID_OFFSET
    stlr    w10, [x11]
    b       .Lafter_command

.Lrestore_position:
    add     x11, x22, #HONK_SAVED_VALID_OFFSET
    ldar    w10, [x11]
    cbz     w10, .Lafter_command
    ldr     s0, [x22, #HONK_SAVED_X_OFFSET]
    ldr     s1, [x22, #HONK_SAVED_Y_OFFSET]
    ldr     s2, [x22, #HONK_SAVED_Z_OFFSET]
    fmov    w10, s0
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lafter_command
    fmov    w10, s1
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lafter_command
    fmov    w10, s2
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lafter_command
    mov     w10, #100
    scvtf   s3, w10
    fabs    s4, s0
    fcmp    s4, s3
    b.gt    .Lafter_command
    fabs    s4, s1
    fcmp    s4, s3
    b.gt    .Lafter_command
    fabs    s4, s2
    fcmp    s4, s3
    b.gt    .Lafter_command
    b       .Lmove_to_position

.Lteleport_position:
    ldr     s0, [x22, #HONK_TARGET_X_OFFSET]
    ldr     s1, [x22, #HONK_TARGET_Y_OFFSET]
    ldr     s2, [x22, #HONK_TARGET_Z_OFFSET]
    // Reject NaN/Infinity and coordinates outside supported map bounds.
    fmov    w10, s0
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lafter_command
    fmov    w10, s1
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lafter_command
    fmov    w10, s2
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lafter_command
    mov     w10, #100
    scvtf   s3, w10
    fabs    s4, s0
    fcmp    s4, s3
    b.gt    .Lafter_command
    fabs    s4, s1
    fcmp    s4, s3
    b.gt    .Lafter_command
    fabs    s4, s2
    fcmp    s4, s3
    b.gt    .Lafter_command
.Lmove_to_position:
    str     s0, [sp, #0]
    str     s1, [sp, #4]
    str     s2, [sp, #8]
    ldr     x0, [x19, #0x18]
    cbz     x0, .Lafter_command
    ldr     s0, [sp, #0]
    ldr     s1, [sp, #4]
    ldr     s2, [sp, #8]
    mov     x1, xzr
goose_reloc_move_position:
    .inst   0x94000000              // BL Rigidbody.MovePosition
    // Clear momentum on arrival without bypassing Unity collision handling.
    ldr     x0, [x19, #0x18]
    fmov    s0, wzr
    fmov    s1, wzr
    fmov    s2, wzr
    mov     x1, xzr
goose_reloc_teleport_clear_velocity:
    .inst   0x94000000              // BL Rigidbody.set_velocity

.Lspawn_primitive:
    // One user-owned experimental primitive at a time. Unity performs the
    // component setup and destruction on this physics/game thread.
    ldr     x0, [x22, #HONK_SPAWNED_OBJECT_OFFSET]
    cbz     x0, .Lspawn_create
    mov     x1, xzr
goose_reloc_destroy_spawned_before_create:
    .inst   0x94000000              // BL UnityEngine.Object.Destroy(Object)
    str     xzr, [x22, #HONK_SPAWNED_OBJECT_OFFSET]
.Lspawn_create:
    sub     w0, w9, #4              // PrimitiveType Sphere=0 .. Cube=3
    mov     x1, xzr
goose_reloc_create_primitive:
    .inst   0x94000000              // BL GameObject.CreatePrimitive(PrimitiveType)
    cbz     x0, .Lafter_command
    str     x0, [x22, #HONK_SPAWNED_OBJECT_OFFSET]
    str     x0, [sp, #16]
    ldr     x0, [x19, #0x18]         // Mover.rb
    cbz     x0, .Lafter_command
    mov     x1, xzr
goose_reloc_spawn_goose_position:
    .inst   0x94000000              // BL Rigidbody.get_position
    fmov    w10, s0
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lafter_command
    fmov    w10, s1
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lafter_command
    fmov    w10, s2
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lafter_command
    fmov    s3, #1.5
    fadd    s1, s1, s3
    str     s0, [sp, #0]
    str     s1, [sp, #4]
    str     s2, [sp, #8]
    ldr     x0, [sp, #16]
    mov     x1, xzr
goose_reloc_spawn_get_transform:
    .inst   0x94000000              // BL GameObject.get_transform
    cbz     x0, .Lafter_command
    mov     x1, xzr
    ldr     s0, [sp, #0]
    ldr     s1, [sp, #4]
    ldr     s2, [sp, #8]
goose_reloc_spawn_set_position:
    .inst   0x94000000              // BL Transform.set_position
    b       .Lafter_command

.Ldestroy_spawned:
    ldr     x0, [x22, #HONK_SPAWNED_OBJECT_OFFSET]
    cbz     x0, .Lafter_command
    mov     x1, xzr
goose_reloc_destroy_spawned:
    .inst   0x94000000              // BL UnityEngine.Object.Destroy(Object)
    str     xzr, [x22, #HONK_SPAWNED_OBJECT_OFFSET]
    b       .Lafter_command

.Lafter_command:
    // Optional global game-rate override. Never change Time from UIKit. Do not
    // touch a paused game; after unpause, an off toggle restores Unity's normal
    // rate and an on toggle applies the bounded requested rate.
    add     x10, x22, #HONK_TIME_SCALE_ENABLED_OFFSET
    ldar    w10, [x10]
    cbz     w10, .Lrestore_time_scale
    mov     x0, xzr
goose_reloc_rate_get_time_scale:
    .inst   0x94000000              // BL UnityEngine.Time.get_timeScale
    fmov    s1, wzr
    fcmp    s0, s1
    b.le    .Lhover
    add     x10, x22, #HONK_TIME_SCALE_OFFSET
    ldar    w10, [x10]
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lhover
    fmov    s0, w10
    fmov    s1, #0.5
    fcmp    s0, s1
    b.lt    .Lhover
    fmov    s1, #2.0
    fcmp    s0, s1
    b.gt    .Lhover
    mov     w10, #1
    add     x11, x22, #HONK_TIME_SCALE_APPLIED_OFFSET
    stlr    w10, [x11]
    mov     x0, xzr
goose_reloc_set_time_scale:
    .inst   0x94000000              // BL UnityEngine.Time.set_timeScale
    b       .Lhover
.Lrestore_time_scale:
    add     x10, x22, #HONK_TIME_SCALE_APPLIED_OFFSET
    ldar    w10, [x10]
    cbz     w10, .Lhover
    mov     x0, xzr
goose_reloc_restore_get_time_scale:
    .inst   0x94000000              // BL UnityEngine.Time.get_timeScale
    fmov    s1, wzr
    fcmp    s0, s1
    b.le    .Lhover
    fmov    s0, #1.0
    mov     x0, xzr
goose_reloc_restore_time_scale:
    .inst   0x94000000              // BL UnityEngine.Time.set_timeScale
    add     x10, x22, #HONK_TIME_SCALE_APPLIED_OFFSET
    stlr    wzr, [x10]

.Lhover:
    // Float mode holds the goose at its current height without disabling
    // colliders or changing gravity configuration. Swimming and dragging are
    // excluded; horizontal velocity remains exactly as the game computed it.
    add     x10, x22, #HONK_HOVER_ENABLED_OFFSET
    ldar    w10, [x10]
    cbz     w10, .Lscale
    cbz     x20, .Lscale
    ldrb    w9, [x20, #0x250]
    cbnz    w9, .Lscale
    ldrb    w9, [x20, #0x14c]
    cbnz    w9, .Lscale
    ldr     x9, [x20, #0x58]
    cbz     x9, .Lhover_draggable
    ldrb    w10, [x9, #0x38]
    cbnz    w10, .Lscale
.Lhover_draggable:
    ldr     x9, [x19, #0x18]
    cbz     x9, .Lscale
    mov     x0, x9
    mov     x1, xzr
goose_reloc_hover_kinematic:
    .inst   0x94000000              // BL Rigidbody.get_isKinematic
    cbnz    w0, .Lscale
    ldr     x0, [x19, #0x18]
    mov     x1, xzr
goose_reloc_hover_get_velocity:
    .inst   0x94000000              // BL Rigidbody.get_velocity
    fmov    w9, s0
    ubfx    w10, w9, #23, #8
    cmp     w10, #255
    b.eq    .Lscale
    fmov    w9, s2
    ubfx    w10, w9, #23, #8
    cmp     w10, #255
    b.eq    .Lscale
    str     s0, [sp, #0]
    str     s2, [sp, #8]
    fmov    s1, wzr
    ldr     x0, [x19, #0x18]
    ldr     s0, [sp, #0]
    ldr     s2, [sp, #8]
    mov     x1, xzr
goose_reloc_hover_set_velocity:
    .inst   0x94000000              // BL Rigidbody.set_velocity

.Lscale:
    // Scale is always derived from the Goose's captured baseline, never from
    // the previously scaled value, so repeated physics ticks cannot compound.
    add     x10, x22, #HONK_SIZE_FACTOR_OFFSET
    ldar    w10, [x10]
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lscale_end
    fmov    s4, w10
    str     s4, [sp, #20]
    fmov    s3, #1.0
    fcmp    s4, s3
    b.eq    .Lscale_check_captured
    fmov    s3, #0.5
    fcmp    s4, s3
    b.lt    .Lscale_end
    fmov    s3, #2.0
    fcmp    s4, s3
    b.gt    .Lscale_end
.Lscale_check_captured:
    ldr     w10, [x22, #HONK_SCALE_CAPTURED_OFFSET]
    cbz     w10, .Lscale_end
    ldr     x9, [x19, #0x10]         // Mover.goose
    cbz     x9, .Lscale_end
    str     x9, [sp, #24]
    ldr     x10, [x22, #HONK_SCALE_GOOSE_OFFSET]
    cmp     x10, x9
    b.ne    .Lcapture_scale
    ldr     w10, [x22, #HONK_SCALE_CAPTURED_OFFSET]
    cbnz    w10, .Lapply_scale
.Lcapture_scale:
    mov     x0, x9
    mov     x1, xzr
goose_reloc_component_transform:
    .inst   0x94000000              // BL Component.get_transform
    cbz     x0, .Lscale_end
    str     x0, [sp, #16]
    mov     x1, xzr
goose_reloc_transform_get_scale:
    .inst   0x94000000              // BL Transform.get_localScale
    fmov    w10, s0
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lscale_end
    fmov    w10, s1
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lscale_end
    fmov    w10, s2
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lscale_end
    str     s0, [x22, #HONK_BASE_SCALE_X_OFFSET]
    str     s1, [x22, #HONK_BASE_SCALE_Y_OFFSET]
    str     s2, [x22, #HONK_BASE_SCALE_Z_OFFSET]
    ldr     x9, [sp, #24]
    str     x9, [x22, #HONK_SCALE_GOOSE_OFFSET]
    mov     w10, #1
    add     x11, x22, #HONK_SCALE_CAPTURED_OFFSET
    stlr    w10, [x11]
    ldr     x0, [sp, #16]
.Lapply_scale:
    ldr     s0, [x22, #HONK_BASE_SCALE_X_OFFSET]
    ldr     s1, [x22, #HONK_BASE_SCALE_Y_OFFSET]
    ldr     s2, [x22, #HONK_BASE_SCALE_Z_OFFSET]
    ldr     s4, [sp, #20]
    fmul    s0, s0, s4
    fmul    s1, s1, s4
    fmul    s2, s2, s4
    fmov    w10, s0
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lscale_end
    fmov    w10, s1
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lscale_end
    fmov    w10, s2
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lscale_end
    ldr     x9, [x22, #HONK_SCALE_GOOSE_OFFSET]
    mov     x0, x9
    mov     x1, xzr
goose_reloc_scale_component_transform:
    .inst   0x94000000              // BL Component.get_transform
    cbz     x0, .Lscale_end
    mov     x1, xzr
goose_reloc_transform_set_scale:
    .inst   0x94000000              // BL Transform.set_localScale
.Lscale_end:
    // The camera helper follows Goose on the exact target build. Its distance
    // is consumed by GooseCameraHelper.LateUpdate; derive changes from the
    // baseline so a slider update never compounds.
.Lcamera:
    add     x10, x22, #HONK_CAMERA_FACTOR_OFFSET
    ldar    w10, [x10]
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lcamera_end
    fmov    s4, w10
    str     s4, [sp, #20]
    fmov    s3, #1.0
    fcmp    s4, s3
    b.eq    .Lcamera_restore_check
    fmov    s3, #0.5
    fcmp    s4, s3
    b.lt    .Lcamera_end
    fmov    s3, #2.0
    fcmp    s4, s3
    b.gt    .Lcamera_end
    b       .Lcamera_ready
.Lcamera_restore_check:
    ldr     w10, [x22, #HONK_CAMERA_CAPTURED_OFFSET]
    cbz     w10, .Lcamera_end
.Lcamera_ready:
    cbz     x20, .Lcamera_end
    ldr     x9, [x20, #0xA0]         // Goose.gooseCameraHelper
    cbz     x9, .Lcamera_end
    ldr     x10, [x22, #HONK_CAMERA_HELPER_OFFSET]
    cmp     x9, x10
    b.ne    .Lcamera_capture
    b       .Lcamera_apply
.Lcamera_capture:
    ldr     s0, [x9, #0x10]          // GooseCameraHelper.distance
    fmov    w10, s0
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lcamera_end
    fmov    s3, wzr
    fcmp    s0, s3
    b.le    .Lcamera_end
    movz    w11, #0xC800
    movk    w11, #0x42C8, lsl #16  // float 100.0
    fmov    s3, w11
    fcmp    s0, s3
    b.gt    .Lcamera_end
    str     s0, [x22, #HONK_CAMERA_BASE_DISTANCE_OFFSET]
    str     x9, [x22, #HONK_CAMERA_HELPER_OFFSET]
    mov     w10, #1
    add     x11, x22, #HONK_CAMERA_CAPTURED_OFFSET
    stlr    w10, [x11]
.Lcamera_apply:
    ldr     s0, [x22, #HONK_CAMERA_BASE_DISTANCE_OFFSET]
    ldr     s4, [sp, #20]
    fmul    s0, s0, s4
    fmov    w10, s0
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lcamera_end
    fmov    s3, wzr
    fcmp    s0, s3
    b.le    .Lcamera_end
    movz    w11, #0xC800
    movk    w11, #0x42C8, lsl #16  // float 100.0
    fmov    s3, w11
    fcmp    s0, s3
    b.gt    .Lcamera_end
    ldr     x9, [x22, #HONK_CAMERA_HELPER_OFFSET]
    str     s0, [x9, #0x10]
.Lcamera_end:
    ldar    x9, [x22, #GOOSE_JUMP_PENDING_OFFSET]
    cbz     w9, .Lmaybe_maintain_cap
    add     x10, x22, #HONK_FLAGS_OFFSET
    ldar    w10, [x10]
    tbnz    w10, #0, .Ljump_enabled
    stlr    xzr, [x22, #GOOSE_JUMP_PENDING_OFFSET]
    b       .Lmaybe_maintain_cap
.Ljump_enabled:

    // Only touch Unity's Time API from this physics-thread hook.
    mov     x0, xzr
goose_reloc_time_scale:
    .inst   0x94000000              // BL UnityEngine.Time.get_timeScale
    fmov    s1, wzr
    fcmp    s0, s1
    b.le    .Lpaused

.Lqueue_retry:
    ldar    x9, [x22, #GOOSE_JUMP_PENDING_OFFSET]
    cbz     w9, .Lmaybe_maintain_cap
    ldr     w10, [x22, #GOOSE_JUMP_HOST_TIME_OFFSET]
    fmov    s0, w10
    lsr     x11, x9, #32
    fmov    s1, w11
    fsub    s2, s0, s1
    fmov    s3, #0.5
    fcmp    s2, s3
    b.gt    .Ldiscard_stale
    fneg    s3, s3
    fcmp    s2, s3
    b.lt    .Ldiscard_stale

    // Consume exactly one queued touch-down. If UIKit enqueues concurrently,
    // compare/exchange retries against the new packed timestamp/count.
    sub     x11, x9, #1
    ldaxr   x10, [x22, #GOOSE_JUMP_PENDING_OFFSET]
    cmp     x10, x9
    b.ne    .Lqueue_retry
    stlxr   w12, x11, [x22, #GOOSE_JUMP_PENDING_OFFSET]
    cbnz    w12, .Lqueue_retry
    b       .Lapply_jump

.Ldiscard_stale:
    // A pause/menu touch expires as one batch, while a newer concurrent tap
    // changes the packed value and survives the compare/exchange.
    ldaxr   x10, [x22, #GOOSE_JUMP_PENDING_OFFSET]
    cmp     x10, x9
    b.ne    .Lqueue_retry
    stlxr   w12, xzr, [x22, #GOOSE_JUMP_PENDING_OFFSET]
    cbnz    w12, .Lqueue_retry
    b       .Lmaybe_maintain_cap

.Lpaused:
    // Unity may run a final FixedUpdate while pausing. Clear taps collected
    // during a paused/menu state; normal paused frames do not enter this hook.
    ldaxr   x10, [x22, #GOOSE_JUMP_PENDING_OFFSET]
    cbz     x10, .Lmaybe_maintain_cap
    stlxr   w12, xzr, [x22, #GOOSE_JUMP_PENDING_OFFSET]
    cbnz    w12, .Lpaused
    b       .Lmaybe_maintain_cap

.Lapply_jump:
    // Consume incompatible presses instead of deferring them until the goose
    // leaves water or stops dragging.
    cbz     x20, .Lmaybe_maintain_cap
    ldrb    w9, [x20, #0x250]        // Goose.isSwimming
    cbnz    w9, .Lmaybe_maintain_cap
    ldrb    w9, [x20, #0x14c]        // Goose.gooseSwimmer.isSwimming
    cbnz    w9, .Lmaybe_maintain_cap
    ldr     x9, [x20, #0x58]         // Goose.dragger
    cbz     x9, .Ldrag_ok
    ldrb    w10, [x9, #0x38]         // Dragger.active
    cbnz    w10, .Lmaybe_maintain_cap
.Ldrag_ok:
    ldr     x9, [x19, #0x18]         // Mover.rb
    cbz     x9, .Lmaybe_maintain_cap
    mov     x0, x9
    mov     x1, xzr
goose_reloc_rb_kinematic:
    .inst   0x94000000              // BL Rigidbody.get_isKinematic
    cbnz    w0, .Lmaybe_maintain_cap

    ldr     x9, [x19, #0x18]
    mov     x0, x9
    mov     x1, xzr
goose_reloc_rb_get_velocity:
    .inst   0x94000000              // BL Rigidbody.get_velocity

    // Reject nonfinite input before arithmetic; no grounded gate is present.
    fmov    w10, s1
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lmaybe_maintain_cap
    fmov    s3, wzr
    fcmp    s1, s3
    b.gt    .Lpositive_velocity
    fmov    s1, s3
.Lpositive_velocity:
    add     x10, x22, #GOOSE_JUMP_IMPULSE_OFFSET
    ldar    w10, [x10]
    fmov    s3, w10
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lmaybe_maintain_cap
    fcmp    s3, s3
    b.vs    .Lmaybe_maintain_cap
    fmov    s4, wzr
    fcmp    s3, s4
    b.le    .Lmaybe_maintain_cap
    fadd    s1, s1, s3              // max(currentY, 0) + configured impulse
    fmov    w10, s1
    ubfx    w11, w10, #23, #8
    cmp     w11, #255               // reject overflow to NaN/Infinity
    b.eq    .Lmaybe_maintain_cap

    // Temporarily raise the game's upward-velocity ceiling only as high as
    // this jump's actual Y velocity. Goose.FixedUpdate clamps to this field
    // after Mover.FixedUpdate; tracking it each tick preserves gravity while
    // avoiding changes to unrelated movement after the jump falls below cap.
    ldr     x11, [x20, #0x20]        // Goose.tuningData
    cbz     x11, .Lmaybe_maintain_cap
    ldr     w10, [x22, #GOOSE_JUMP_CAP_ACTIVE_OFFSET]
    cbz     w10, .Lsave_original_cap
    ldr     x12, [x22, #GOOSE_JUMP_TUNING_DATA_OFFSET]
    cmp     x12, x11
    b.eq    .Lset_jump_cap
    cbz     x12, .Lsave_original_cap
    ldr     s4, [x22, #GOOSE_JUMP_ORIGINAL_CAP_OFFSET]
    str     s4, [x12, #0x18]
.Lsave_original_cap:
    ldr     s4, [x11, #0x18]
    str     s4, [x22, #GOOSE_JUMP_ORIGINAL_CAP_OFFSET]
    str     x11, [x22, #GOOSE_JUMP_TUNING_DATA_OFFSET]
    mov     w10, #1
    str     w10, [x22, #GOOSE_JUMP_CAP_ACTIVE_OFFSET]
.Lset_jump_cap:
    str     s1, [x11, #0x18]
    str     s0, [sp, #0]            // preserve horizontal X/Z across setter call
    str     s2, [sp, #8]
    ldr     x0, [x19, #0x18]
    ldr     s0, [sp, #0]
    ldr     s2, [sp, #8]
    mov     x1, xzr
goose_reloc_rb_set_velocity:
    .inst   0x94000000              // BL Rigidbody.set_velocity
    b       .Ldone

.Lmaybe_maintain_cap:
    ldr     w9, [x22, #GOOSE_JUMP_CAP_ACTIVE_OFFSET]
    cbz     w9, .Ldone
    cbz     x20, .Lrestore_cap
    ldrb    w9, [x20, #0x250]
    cbnz    w9, .Lrestore_cap
    ldrb    w9, [x20, #0x14c]
    cbnz    w9, .Lrestore_cap
    ldr     x9, [x20, #0x58]
    cbz     x9, .Lmaintain_drag_ok
    ldrb    w10, [x9, #0x38]
    cbnz    w10, .Lrestore_cap
.Lmaintain_drag_ok:
    ldr     x11, [x22, #GOOSE_JUMP_TUNING_DATA_OFFSET]
    cbz     x11, .Lrestore_cap
    ldr     x12, [x20, #0x20]
    cmp     x12, x11
    b.ne    .Lrestore_cap
    ldr     x9, [x19, #0x18]
    cbz     x9, .Lrestore_cap
    mov     x0, x9
    mov     x1, xzr
goose_reloc_rb_get_velocity_maintain:
    .inst   0x94000000              // BL Rigidbody.get_velocity
    fmov    w10, s1
    ubfx    w10, w10, #23, #8
    cmp     w10, #255
    b.eq    .Lrestore_cap
    ldr     s2, [x22, #GOOSE_JUMP_ORIGINAL_CAP_OFFSET]
    fcmp    s1, s2
    b.le    .Lrestore_cap
    str     s1, [x11, #0x18]
    b       .Ldone

.Lrestore_cap:
    ldr     x11, [x22, #GOOSE_JUMP_TUNING_DATA_OFFSET]
    cbz     x11, .Lclear_cap_state
    ldr     s1, [x22, #GOOSE_JUMP_ORIGINAL_CAP_OFFSET]
    str     s1, [x11, #0x18]
.Lclear_cap_state:
    str     wzr, [x22, #GOOSE_JUMP_CAP_ACTIVE_OFFSET]
    str     xzr, [x22, #GOOSE_JUMP_TUNING_DATA_OFFSET]

.Ldone:
.Lupdate_camera_position:
    mov     x0, xzr
    mov     x1, xzr
goose_reloc_camera_main_position:
    .inst   0x94000000              // BL Camera.get_main
    cbz     x0, .Lcamera_position_invalid
    mov     x1, xzr
goose_reloc_camera_transform_position:
    .inst   0x94000000              // BL Component.get_transform
    cbz     x0, .Lcamera_position_invalid
    mov     x1, xzr
goose_reloc_camera_get_position:
    .inst   0x94000000              // BL Transform.get_position
    fmov    w10, s0
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lcamera_position_invalid
    fmov    w10, s1
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lcamera_position_invalid
    fmov    w10, s2
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lcamera_position_invalid
    fmov    w10, s0
    add     x9, x22, #HONK_CAMERA_POSITION_X_OFFSET
    stlr    w10, [x9]
    fmov    w10, s1
    add     x9, x22, #HONK_CAMERA_POSITION_Y_OFFSET
    stlr    w10, [x9]
    fmov    w10, s2
    add     x9, x22, #HONK_CAMERA_POSITION_Z_OFFSET
    stlr    w10, [x9]
    mov     w10, #1
    add     x9, x22, #HONK_CAMERA_POSITION_VALID_OFFSET
    stlr    w10, [x9]
    b       .Ldone_return
.Lcamera_position_invalid:
    add     x9, x22, #HONK_CAMERA_POSITION_VALID_OFFSET
    stlr    wzr, [x9]
.Ldone_return:
    mov     x0, x20
    mov     x1, x22
    bl      goose_color_update
    ldr     x22, [sp, #32]
    ldr     x30, [sp, #40]
    add     sp, sp, #48
    ret

.size goose_jump_helper, .-goose_jump_helper

// A second static hook handles Body.Update. Reserve a deterministic entry
// inside the same verified text padding so its patch target is reproducible.
.space 0x1000 - (. - goose_jump_helper), 0
.global goose_shoo_guard
.type goose_shoo_guard, %function
goose_shoo_guard:
goose_shoo_reloc_data_adrp:
    .inst   0x90000009              // ADRP x9, goose_jump_data
goose_shoo_reloc_data_add:
    .inst   0x91000129              // ADD x9, x9, #lo12(goose_jump_data)
    add     x10, x9, #HONK_FLAGS_OFFSET
    ldar    w10, [x10]
    tbnz    w10, #2, .Lshoo_disable

    // Honk-Menu uses 100000 as a sentinel. Clear only our own exact sentinel
    // on disable; preserve ordinary NPC cooldown timestamps.
    ldr     w11, [x0, #0x90]        // Body.shooReadiness.timeAllowedToShooAgain
    movz    w12, #0x5000
    movk    w12, #0x47c3, lsl #16   // float 100000.0
    cmp     w11, w12
    b.ne    .Lshoo_resume
    str     wzr, [x0, #0x90]
    b       .Lshoo_resume
.Lshoo_disable:
    movz    w11, #0x5000
    movk    w11, #0x47c3, lsl #16   // float 100000.0
    str     w11, [x0, #0x90]
.Lshoo_resume:
    // Capture and scale each live Body from this verified per-NPC update hook.
    // The fixed table avoids managed enumeration and is reset when the Goose
    // Mover changes (scene/player replacement).
    sub     sp, sp, #80
    str     x20, [sp, #32]
    str     x22, [sp, #40]
    str     x0, [sp, #24]
    str     x30, [sp, #72]
    str     wzr, [sp, #4]
    mov     x22, x9
    ldr     w10, [x22, #HONK_NPC_SIZE_FACTOR_OFFSET]
    fmov    s4, w10
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lnpc_scale_finish
    fmov    s3, #0.5
    fcmp    s4, s3
    b.lt    .Lnpc_scale_finish
    fmov    s3, #2.0
    fcmp    s4, s3
    b.gt    .Lnpc_scale_finish
    str     w10, [sp, #0]
    ldr     x11, [sp, #24]
    add     x9, x22, #HONK_NPC_SCALE_TABLE_OFFSET
    mov     w12, #HONK_NPC_SCALE_ENTRY_COUNT
.Lnpc_scale_find:
    ldar    x13, [x9]
    cmp     x13, x11
    b.eq    .Lnpc_scale_found
    cbz     x13, .Lnpc_scale_capture
    add     x9, x9, #HONK_NPC_SCALE_ENTRY_SIZE
    subs    w12, w12, #1
    b.ne    .Lnpc_scale_find
    b       .Lnpc_scale_finish
.Lnpc_scale_capture:
    stlr    x11, [x9]
    str     x9, [sp, #8]
    mov     x0, x11
    mov     x1, xzr
goose_reloc_npc_component_transform:
    .inst   0x94000000              // BL Component.get_transform
    cbz     x0, .Lnpc_scale_finish
    str     x0, [sp, #16]
    mov     x1, xzr
goose_reloc_npc_transform_get_scale:
    .inst   0x94000000              // BL Transform.get_localScale
    fmov    w10, s0
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lnpc_scale_finish
    fmov    w10, s1
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lnpc_scale_finish
    fmov    w10, s2
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lnpc_scale_finish
    ldr     x9, [sp, #8]
    str     s0, [x9, #8]
    str     s1, [x9, #12]
    str     s2, [x9, #16]
    mov     w10, #1
    str     w10, [x9, #20]
    str     w10, [sp, #4]
    b       .Lnpc_scale_apply
.Lnpc_scale_found:
    str     x9, [sp, #8]
    ldr     w10, [x9, #20]
    cbz     w10, .Lnpc_scale_finish
    mov     w10, #1
    str     w10, [sp, #4]
.Lnpc_scale_apply:
    ldr     s4, [sp, #0]
    fmov    w10, s4
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lnpc_scale_finish
    ldr     x0, [sp, #24]
    mov     x1, xzr
goose_reloc_npc_apply_transform:
    .inst   0x94000000              // BL Component.get_transform
    cbz     x0, .Lnpc_scale_finish
    str     x0, [sp, #16]
    ldr     x9, [sp, #8]
    ldr     s0, [x9, #8]
    ldr     s1, [x9, #12]
    ldr     s2, [x9, #16]
    fmul    s0, s0, s4
    fmul    s1, s1, s4
    fmul    s2, s2, s4
    fmov    w10, s0
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lnpc_scale_finish
    fmov    w10, s1
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lnpc_scale_finish
    fmov    w10, s2
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lnpc_scale_finish
    ldr     x0, [sp, #16]
    mov     x1, xzr
goose_reloc_npc_transform_set_scale:
    .inst   0x94000000              // BL Transform.set_localScale
.Lnpc_scale_finish:
    ldr     w10, [sp, #4]
    cbz     w10, .Lnpc_scale_restore_regs
    ldr     x9, [sp, #8]
    add     x10, x22, #HONK_FLAGS_OFFSET
    ldar    w10, [x10]
    tbnz    w10, #3, .Lnpc_esp_project
    str     wzr, [x9, #36]
    b       .Lnpc_scale_restore_regs
.Lnpc_esp_project:
    ldr     x0, [sp, #24]
    mov     x1, xzr
goose_reloc_npc_esp_transform:
    .inst   0x94000000              // BL Component.get_transform
    cbz     x0, .Lnpc_esp_hide
    mov     x1, xzr
goose_reloc_npc_esp_world_position:
    .inst   0x94000000              // BL Transform.get_position
    fmov    w10, s0
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lnpc_esp_hide
    fmov    w10, s1
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lnpc_esp_hide
    fmov    w10, s2
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lnpc_esp_hide
    fmov    s3, #1.5
    fadd    s1, s1, s3
    str     s0, [sp, #48]
    str     s1, [sp, #52]
    str     s2, [sp, #56]
    mov     x0, xzr
goose_reloc_npc_camera_main:
    .inst   0x94000000              // BL Camera.get_main
    cbz     x0, .Lnpc_esp_hide
    mov     x1, xzr
    ldr     s0, [sp, #48]
    ldr     s1, [sp, #52]
    ldr     s2, [sp, #56]
goose_reloc_npc_world_to_screen:
    .inst   0x94000000              // BL Camera.WorldToScreenPoint(Vector3)
    str     s0, [sp, #48]
    str     s1, [sp, #52]
    str     s2, [sp, #56]
    mov     x0, xzr
    mov     x1, xzr
goose_reloc_npc_screen_width:
    .inst   0x94000000              // BL Screen.get_width
    cmp     w0, #0
    b.le    .Lnpc_esp_hide
    str     w0, [sp, #60]
    str     w0, [x22, #HONK_NPC_SCREEN_WIDTH_OFFSET]
    mov     x0, xzr
    mov     x1, xzr
goose_reloc_npc_screen_height:
    .inst   0x94000000              // BL Screen.get_height
    cmp     w0, #0
    b.le    .Lnpc_esp_hide
    str     w0, [sp, #64]
    str     w0, [x22, #HONK_NPC_SCREEN_HEIGHT_OFFSET]
    ldr     s0, [sp, #48]
    ldr     s1, [sp, #52]
    ldr     s2, [sp, #56]
    fmov    w10, s0
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lnpc_esp_hide
    fmov    w10, s1
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lnpc_esp_hide
    fmov    w10, s2
    ubfx    w11, w10, #23, #8
    cmp     w11, #255
    b.eq    .Lnpc_esp_hide
    fcmp    s2, #0.0
    b.le    .Lnpc_esp_hide
    fmov    s3, wzr
    fcmp    s0, s3
    b.lt    .Lnpc_esp_hide
    ldr     w10, [sp, #60]
    scvtf   s3, w10
    fcmp    s0, s3
    b.gt    .Lnpc_esp_hide
    fcmp    s1, s3
    b.lt    .Lnpc_esp_hide
    ldr     w10, [sp, #64]
    scvtf   s3, w10
    fcmp    s1, s3
    b.gt    .Lnpc_esp_hide
    ldr     x9, [sp, #8]
    add     x14, x9, #24
    fmov    w10, s0
    stlr    w10, [x14]
    add     x14, x9, #28
    fmov    w10, s1
    stlr    w10, [x14]
    str     s2, [x9, #32]
    mov     w10, #1
    add     x14, x9, #36
    stlr    w10, [x14]
    b       .Lnpc_scale_restore_regs
.Lnpc_esp_hide:
    ldr     x9, [sp, #8]
    add     x14, x9, #36
    stlr    wzr, [x14]
.Lnpc_scale_restore_regs:
    ldr     x0, [sp, #24]
    ldr     x20, [sp, #32]
    ldr     x22, [sp, #40]
    ldr     x30, [sp, #72]
    add     sp, sp, #80
goose_reloc_shoo_displaced:
    .inst   0xA9BE4FF4              // displaced STP x20,x19,[sp,#-0x20]!
goose_reloc_shoo_continue:
    .inst   0x14000000              // B Body.Update+4
.size goose_shoo_guard, .-goose_shoo_guard

.space 0x1800 - (. - goose_jump_helper), 0
.global goose_camera_free_hook
.type goose_camera_free_hook, %function
goose_camera_free_hook:
goose_reloc_camera_hook_data_adrp:
    .inst   0x90000009              // ADRP x9, goose_jump_data
goose_reloc_camera_hook_data_add:
    .inst   0x91000129              // ADD x9, x9, #lo12(goose_jump_data)
    add     x10, x9, #HONK_FLAGS_OFFSET
    ldar    w10, [x10]
    tbnz    w10, #5, .Lcamera_first_person
    tbz     w10, #4, .Lcamera_follow_original

    // This hook is GooseCameraHelper.LateUpdate(this). The Goose stores its
    // camera Transform at +0x238; bypassing the follow update only while the
    // toggle is on leaves the original camera path intact when disabled.
    ldr     x11, [x0, #0x18]         // GooseCameraHelper.goose
    cbz     x11, .Lcamera_follow_original
    ldr     x11, [x11, #0x238]      // Goose.cameraTransform
    cbz     x11, .Lcamera_follow_original
    add     x10, x9, #HONK_FREE_CAMERA_X_OFFSET
    ldar    w12, [x10]
    fmov    s0, w12
    add     x10, x9, #HONK_FREE_CAMERA_Y_OFFSET
    ldar    w12, [x10]
    fmov    s1, w12
    add     x10, x9, #HONK_FREE_CAMERA_Z_OFFSET
    ldar    w12, [x10]
    fmov    s2, w12
    fmov    w12, s0
    ubfx    w12, w12, #23, #8
    cmp     w12, #255
    b.eq    .Lcamera_follow_original
    fmov    w12, s1
    ubfx    w12, w12, #23, #8
    cmp     w12, #255
    b.eq    .Lcamera_follow_original
    fmov    w12, s2
    ubfx    w12, w12, #23, #8
    cmp     w12, #255
    b.eq    .Lcamera_follow_original
    mov     w12, #100
    scvtf   s3, w12
    fabs    s4, s0
    fcmp    s4, s3
    b.gt    .Lcamera_follow_original
    fabs    s4, s1
    fcmp    s4, s3
    b.gt    .Lcamera_follow_original
    fabs    s4, s2
    fcmp    s4, s3
    b.gt    .Lcamera_follow_original

    sub     sp, sp, #48
    stp     x19, x20, [sp]
    stp     x21, x22, [sp, #16]
    str     x30, [sp, #32]
    mov     x20, x11
    mov     x0, x20
    mov     x1, xzr
goose_reloc_camera_free_set_position:
    .inst   0x94000000              // BL Transform.set_position
    ldp     x19, x20, [sp]
    ldp     x21, x22, [sp, #16]
    ldr     x30, [sp, #32]
    add     sp, sp, #48
    ret

.Lcamera_first_person:
    // First-person mode reuses Goose.cameraTransform and the verified Goose.head
    // Transform. A short forward offset avoids placing the camera at the center
    // of the head mesh. Missing objects fall through to the original follow rig.
    ldr     x12, [x0, #0x18]         // GooseCameraHelper.goose
    cbz     x12, .Lcamera_follow_original
    ldr     x20, [x12, #0x238]      // Goose.cameraTransform
    cbz     x20, .Lcamera_follow_original
    ldr     x19, [x12, #0x1B0]      // Goose.head
    cbz     x19, .Lcamera_follow_original
    sub     sp, sp, #64
    str     x19, [sp, #0]
    str     x20, [sp, #8]
    str     x30, [sp, #16]
    mov     x0, x19
    mov     x1, xzr
goose_reloc_camera_firstperson_get_position:
    .inst   0x94000000              // BL Transform.get_position
    str     s0, [sp, #24]
    str     s1, [sp, #28]
    str     s2, [sp, #32]
    ldr     x0, [sp, #0]
    mov     x1, xzr
goose_reloc_camera_firstperson_get_forward:
    .inst   0x94000000              // BL Transform.get_forward
    movz    w12, #0x999a
    movk    w12, #0x3e19, lsl #16   // float 0.15
    fmov    s3, w12
    ldr     s4, [sp, #24]
    ldr     s5, [sp, #28]
    ldr     s6, [sp, #32]
    fmadd   s0, s0, s3, s4
    fmadd   s1, s1, s3, s5
    fmadd   s2, s2, s3, s6
    ldr     x0, [sp, #8]
    mov     x1, xzr
goose_reloc_camera_firstperson_set_position:
    .inst   0x94000000              // BL Transform.set_position
    ldr     x0, [sp, #0]
    mov     x1, xzr
goose_reloc_camera_firstperson_get_rotation:
    .inst   0x94000000              // BL Transform.get_rotation
    ldr     x0, [sp, #8]
    mov     x1, xzr
goose_reloc_camera_firstperson_set_rotation:
    .inst   0x94000000              // BL Transform.set_rotation
    ldr     x19, [sp, #0]
    ldr     x20, [sp, #8]
    ldr     x30, [sp, #16]
    add     sp, sp, #64
    ret

.Lcamera_follow_original:
goose_reloc_camera_hook_displaced:
    .inst   0xD10203FF              // GooseCameraHelper.LateUpdate sub sp,sp,#0x80
goose_reloc_camera_original_continue:
    .inst   0x14000000              // B GooseCameraHelper.LateUpdate+4
.size goose_camera_free_hook, .-goose_camera_free_hook

// Goose material tinting uses the verified Renderer and Material API entries.
// The generic Renderer enumeration's exact MethodInfo pointer slot and the
// runtime _Color string literal slot are supplied by the original IL2CPP image.
.p2align 2
.global goose_color_update
.type goose_color_update, %function
goose_color_update:
    cbz     x0, .Lcolor_return
    sub     sp, sp, #96
    stp     x19, x20, [sp, #0]
    stp     x21, x22, [sp, #16]
    stp     x23, x24, [sp, #32]
    stp     x25, x26, [sp, #48]
    str     x30, [sp, #64]
    mov     x19, x0                  // Goose component
    mov     x20, x1                  // shared state
    add     x10, x20, #HONK_FLAGS_OFFSET
    ldar    w21, [x10]
    tbnz    w21, #6, .Lcolor_enabled
    ldr     w22, [x20, #HONK_RENDERER_COLOR_COUNT_OFFSET]
    mov     w10, #HONK_RENDERER_COLOR_ENTRY_COUNT
    cmp     w22, w10
    csel    w22, w22, w10, ls
    cbz     w22, .Lcolor_finish
    mov     w23, wzr
.Lcolor_restore_loop:
    cmp     w23, w22
    b.hs    .Lcolor_clear_count
    add     x24, x20, #HONK_RENDERER_COLOR_TABLE_OFFSET
    mov     x25, #HONK_RENDERER_COLOR_ENTRY_SIZE
    madd    x24, x23, x25, x24
    ldr     x0, [x24, #8]
    cbz     x0, .Lcolor_restore_next
    ldr     s0, [x24, #16]
    ldr     s1, [x24, #20]
    ldr     s2, [x24, #24]
    ldr     s3, [x24, #28]
    mov     x1, xzr
goose_reloc_color_material_restore:
    .inst   0x94000000              // BL Material.set_color
.Lcolor_restore_next:
    add     w23, w23, #1
    b       .Lcolor_restore_loop
.Lcolor_clear_count:
    str     wzr, [x20, #HONK_RENDERER_COLOR_COUNT_OFFSET]
    b       .Lcolor_finish

.Lcolor_enabled:
    ldr     w22, [x20, #HONK_RENDERER_COLOR_COUNT_OFFSET]
    cbnz    w22, .Lcolor_apply
    // Capture original color from every renderer's first material. Clamp the
    // table to 32 renderers; iteration stays entirely on Unity's game thread.
    mov     x0, x19
    mov     w1, wzr
goose_reloc_color_get_renderers_method_adrp:
    .inst   0x9000000A              // ADRP x10, Component.GetComponentsInChildren<Renderer>(bool) MethodInfo slot
goose_reloc_color_get_renderers_method_add:
    .inst   0x9100014A              // ADD x10, x10, #lo12(method slot)
    ldr     x2, [x10]
goose_reloc_color_get_renderers:
    .inst   0x94000000              // BL Component.GetComponentsInChildren<Renderer>(bool)
    cbz     x0, .Lcolor_finish
    mov     x24, x0                  // Il2CppArray<Renderer>
    ldr     x25, [x24, #0x18]       // Il2CppArray.max_length
    mov     x10, #HONK_RENDERER_COLOR_ENTRY_COUNT
    cmp     x25, x10
    csel    x25, x25, x10, lo
    add     x26, x24, #0x20         // Il2CppArray vector
    mov     x23, xzr
.Lcolor_capture_loop:
    cmp     x23, x25
    b.hs    .Lcolor_apply
    ldr     x0, [x26, x23, lsl #3]
    cbz     x0, .Lcolor_capture_next
    str     x0, [sp, #72]
    mov     x1, xzr
goose_reloc_color_get_material:
    .inst   0x94000000              // BL Renderer.get_material
    cbz     x0, .Lcolor_capture_next
    str     x0, [sp, #80]
goose_reloc_color_string_adrp:
    .inst   0x9000000A              // ADRP x10, _Color string literal slot
goose_reloc_color_string_add:
    .inst   0x9100014A              // ADD x10, x10, #lo12(_Color string slot)
    ldr     x1, [x10]
    cbz     x1, .Lcolor_capture_next
    mov     x2, xzr
goose_reloc_color_get_color:
    .inst   0x94000000              // BL Material.GetColor(string)
    ldr     w12, [x20, #HONK_RENDERER_COLOR_COUNT_OFFSET]
    cmp     w12, #HONK_RENDERER_COLOR_ENTRY_COUNT
    b.hs    .Lcolor_apply
    add     x13, x20, #HONK_RENDERER_COLOR_TABLE_OFFSET
    mov     x14, #HONK_RENDERER_COLOR_ENTRY_SIZE
    madd    x13, x12, x14, x13
    ldr     x14, [sp, #72]
    str     x14, [x13]
    ldr     x14, [sp, #80]
    str     x14, [x13, #8]
    str     s0, [x13, #16]
    str     s1, [x13, #20]
    str     s2, [x13, #24]
    str     s3, [x13, #28]
    add     w12, w12, #1
    add     x14, x20, #HONK_RENDERER_COLOR_COUNT_OFFSET
    stlr    w12, [x14]
.Lcolor_capture_next:
    add     x23, x23, #1
    b       .Lcolor_capture_loop

.Lcolor_apply:
    ldr     w22, [x20, #HONK_RENDERER_COLOR_COUNT_OFFSET]
    mov     w10, #HONK_RENDERER_COLOR_ENTRY_COUNT
    cmp     w22, w10
    csel    w22, w22, w10, ls
    mov     w23, wzr
.Lcolor_apply_loop:
    cmp     w23, w22
    b.hs    .Lcolor_finish
    add     x24, x20, #HONK_RENDERER_COLOR_TABLE_OFFSET
    mov     x25, #HONK_RENDERER_COLOR_ENTRY_SIZE
    madd    x24, x23, x25, x24
    ldr     x0, [x24, #8]
    cbz     x0, .Lcolor_apply_next
    add     x10, x20, #HONK_GOOSE_COLOR_R_OFFSET
    ldar    w10, [x10]
    fmov    s0, w10
    add     x10, x20, #HONK_GOOSE_COLOR_G_OFFSET
    ldar    w10, [x10]
    fmov    s1, w10
    add     x10, x20, #HONK_GOOSE_COLOR_B_OFFSET
    ldar    w10, [x10]
    fmov    s2, w10
    add     x10, x20, #HONK_GOOSE_COLOR_A_OFFSET
    ldar    w10, [x10]
    fmov    s3, w10
    mov     x1, xzr
goose_reloc_color_material_apply:
    .inst   0x94000000              // BL Material.set_color
.Lcolor_apply_next:
    add     w23, w23, #1
    b       .Lcolor_apply_loop

.Lcolor_finish:
    ldp     x19, x20, [sp, #0]
    ldp     x21, x22, [sp, #16]
    ldp     x23, x24, [sp, #32]
    ldp     x25, x26, [sp, #48]
    ldr     x30, [sp, #64]
    add     sp, sp, #96
.Lcolor_return:
    ret
.size goose_color_update, .-goose_color_update
