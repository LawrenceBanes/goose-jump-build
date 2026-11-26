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
    str     x19, [x22, #GOOSE_JUMP_LAST_MOVER_OFFSET]
.Lsame_mover:
    ldar    x9, [x22, #GOOSE_JUMP_PENDING_OFFSET]
    cbz     w9, .Lmaybe_maintain_cap

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
    ldr     s3, [x22, #GOOSE_JUMP_IMPULSE_OFFSET]
    fmov    w10, s3
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
