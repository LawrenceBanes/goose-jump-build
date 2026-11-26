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
    b       .Lafter_command

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
    ldr     x22, [sp, #32]
    ldr     x30, [sp, #40]
    add     sp, sp, #48
    ret

.size goose_jump_helper, .-goose_jump_helper
