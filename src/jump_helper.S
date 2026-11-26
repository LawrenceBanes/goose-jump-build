/*
 * ARM64 helper inserted at Mover.FixedUpdate after Rigidbody.set_velocity.
 * The replaced original instruction, ldr x20, [x19, #16], is repeated here.
 * All executable and data symbols are version-pinned by tools/build_ipa.py.
 */

.text
.p2align 2
.global goose_jump_helper
.type goose_jump_helper, %function

goose_jump_helper:
    sub     sp, sp, #32
    str     x22, [sp, #16]
    str     x30, [sp, #24]
    ldr     x20, [x19, #16]          // displaced original instruction

goose_reloc_data_adrp:
    .inst   0x90000016              // ADRP x22, goose_jump_data
goose_reloc_data_add:
    .inst   0x910002d6              // ADD x22, x22, #lo12(goose_jump_data)

    // Reset per-goose state after a scene replaces the Mover.
    ldr     x9, [x22, #24]
    cmp     x9, x19
    b.eq    1f
    str     x19, [x22, #24]
    stlr    wzr, [x22]               // request
    str     wzr, [x22, #4]           // airborne latch
    str     wzr, [x22, #8]           // cooldown remaining
    str     wzr, [x22, #32]          // stable grounded frames
1:
    // Cooldown advances in physics time and freezes naturally while paused.
    mov     x0, xzr
goose_reloc_time_fixed:
    .inst   0x94000000              // BL UnityEngine.Time.get_fixedDeltaTime
    ldr     s1, [x22, #8]
    fsub    s1, s1, s0
    fmov    s2, wzr
    fcmp    s1, s2
    b.gt    2f
    fmov    s1, wzr
2:
    str     s1, [x22, #8]

    ldar    w9, [x22]
    cbz     w9, 8f
    stlr    wzr, [x22]               // consume every touch once

    // A touch cannot survive an in-game pause even if FixedUpdate resumes fast.
    mov     x0, xzr
goose_reloc_time_scale:
    .inst   0x94000000              // BL UnityEngine.Time.get_timeScale
    fmov    s1, wzr
    fcmp    s0, s1
    b.le    9f

    // Ignore stale menu/transition touches and negative clock deltas.
    mov     x0, xzr
goose_reloc_time_unscaled:
    .inst   0x94000000              // BL UnityEngine.Time.get_unscaledTime
    ldr     s1, [x22, #20]
    fsub    s0, s0, s1
    fmov    s1, #0.5
    fcmp    s0, s1
    b.gt    9f
    fmov    s1, wzr
    fcmp    s0, s1
    b.mi    9f

    cbz     x20, 9f
    ldrb    w9, [x20, #0x250]        // Goose.isSwimming
    cbnz    w9, 9f
    ldrb    w9, [x20, #0x14c]        // Goose.gooseSwimmer.isSwimming
    cbnz    w9, 9f

    // Do not add impulse while the Goose is actively dragging or kinematic.
    ldr     x9, [x20, #0x58]         // Goose.dragger
    cbz     x9, 3f
    ldrb    w10, [x9, #0x38]         // Dragger.active
    cbnz    w10, 9f
3:
    ldr     x9, [x19, #0x18]         // Mover.rb
    cbz     x9, 9f
    mov     x0, x9
    mov     x1, xzr
goose_reloc_rb_kinematic:
    .inst   0x94000000              // BL Rigidbody.get_isKinematic
    cbnz    w0, 9f

    // GooseGround: alwaysGrounded, static contacts, or prop contact list.
    ldrb    w9, [x20, #0x105]
    cbnz    w9, 4f
    ldr     w9, [x20, #0x108]
    cmp     w9, #0
    b.gt    4f
    ldr     x9, [x20, #0x110]
    cbz     x9, 9f
    ldr     w9, [x9, #0x18]         // List<Prop>._size
    cmp     w9, #0
    b.le    9f
4:
    // A positive Y velocity means airborne; stale contacts cannot retrigger.
    ldr     x9, [x19, #0x18]
    mov     x0, x9
    mov     x1, xzr
goose_reloc_rb_get_velocity:
    .inst   0x94000000              // BL Rigidbody.get_velocity
    str     s0, [sp, #0]
    str     s1, [sp, #4]
    str     s2, [sp, #8]
    fmov    s3, wzr
    fcmp    s1, s3
    b.gt    9f

    // Require two grounded physics observations before clearing the airborne
    // latch. This tolerates one stale collision contact at takeoff/apex.
    ldr     w9, [x22, #4]
    cbz     w9, 5f
    ldr     w9, [x22, #32]
    add     w9, w9, #1
    str     w9, [x22, #32]
    cmp     w9, #2
    b.lo    9f
    str     wzr, [x22, #4]
    str     wzr, [x22, #32]
    b       6f
5:
    str     wzr, [x22, #32]
6:
    ldr     s1, [x22, #8]
    fmov    s2, wzr
    fcmp    s1, s2
    b.gt    9f

    // Clamp configured strength to the game's own upward velocity ceiling.
    ldr     x9, [x20, #0x20]         // Goose.tuningData
    cbz     x9, 9f
    ldr     s2, [x9, #0x18]         // GooseTuningData.maxUpwardVelocity
    ldr     s1, [x22, #12]          // configured jump impulse
    fmin    s1, s1, s2
    fmov    s2, wzr
    fcmp    s1, s2
    b.le    9f

    ldr     x0, [x19, #0x18]
    ldr     s0, [sp, #0]
    ldr     s2, [sp, #8]
    mov     x1, xzr
goose_reloc_rb_set_velocity:
    .inst   0x94000000              // BL Rigidbody.set_velocity
    mov     w9, #1
    str     w9, [x22, #4]
    str     wzr, [x22, #32]
    ldr     s1, [x22, #16]
    str     s1, [x22, #8]
    b       9f

8:
    // Keep the landing latch current even when the player waits before tapping.
    // A stable contact over two physics updates is required to re-arm jumping.
    ldr     w9, [x22, #4]
    cbz     w9, 9f
    cbz     x20, .Lrearm_reset
    ldrb    w9, [x20, #0x250]
    cbnz    w9, .Lrearm_reset
    ldrb    w9, [x20, #0x14c]
    cbnz    w9, .Lrearm_reset
    ldr     x9, [x20, #0x58]
    cbz     x9, .Lrearm_drag_ok
    ldrb    w10, [x9, #0x38]
    cbnz    w10, .Lrearm_reset
.Lrearm_drag_ok:
    ldrb    w9, [x20, #0x105]
    cbnz    w9, .Lrearm_grounded
    ldr     w9, [x20, #0x108]
    cmp     w9, #0
    b.gt    .Lrearm_grounded
    ldr     x9, [x20, #0x110]
    cbz     x9, .Lrearm_reset
    ldr     w9, [x9, #0x18]
    cmp     w9, #0
    b.le    .Lrearm_reset
.Lrearm_grounded:
    ldr     x9, [x19, #0x18]
    cbz     x9, .Lrearm_reset
    mov     x0, x9
    mov     x1, xzr
goose_reloc_rb_get_velocity_rearm:
    .inst   0x94000000              // BL Rigidbody.get_velocity
    fmov    s3, wzr
    fcmp    s1, s3
    b.gt    .Lrearm_reset
    ldr     w9, [x22, #32]
    add     w9, w9, #1
    str     w9, [x22, #32]
    cmp     w9, #2
    b.lo    9f
    str     wzr, [x22, #4]
.Lrearm_reset:
    str     wzr, [x22, #32]

9:
    ldr     x22, [sp, #16]
    ldr     x30, [sp, #24]
    add     sp, sp, #32
    ret

.size goose_jump_helper, .-goose_jump_helper
