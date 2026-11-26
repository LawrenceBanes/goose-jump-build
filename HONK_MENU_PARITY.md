# Honk-Menu iOS parity

## Reference and reuse boundary

- Reference: [xZeko-SRC/Honk-Menu](https://github.com/xZeko-SRC/Honk-Menu), default-branch commit `6ba124e85d79dbbc6658d88e63f89019c0c2b7d3`.
- The isolated checkout is `reference/Honk-Menu/` and is ignored by Git.
- The repository has no `LICENSE` file and GitHub reports no recognized license. Its C# implementation and artwork are therefore not copied into this project or the public build repository. The upstream feature descriptions and numeric practice destinations are used as behavioral references; the iOS code and interface are original.
- Upstream dependencies include MelonLoader, Harmony, Mono.Cecil, Assembly-CSharp and UnityEngine managed assemblies. This Windows/.NET Framework 4.8 plugin is not an iOS-compatible IL2CPP component and is not loaded by the port.

## Feature inventory

| Upstream feature | Actual behavior observed in source | Classification for iOS | Honk-Menu iOS v0.2.0 status |
|---|---|---|---|
| Native menu, categories, shortcut help, credits | IMGUI windows; menu opens after honking; keyboard/gamepad handlers | UIKit adaptation | Native touch shell with Move, Teleport, Camera, Goose/NPC, World, and Experimental pages. Native credits/source attribution UI is not yet ported. |
| Jump toggle / strength | Input-triggered Rigidbody jump | Movement hook | Implemented in the pinned Mover hook with touchscreen input, strength setting, and repeated airborne taps. |
| Horizontal speed | Changes `Mover.currentSpeed` under a keyboard toggle | Movement hook | Implemented as a bounded X/Z velocity scale; original movement computes the direction each tick. |
| Floating | Repeatedly applies upward force while enabled | Rigidbody physics | Implemented as a vertical velocity lock; X/Z movement and collision remain active. It is not noclip. |
| Noclip | Disables goose colliders and uses free movement | Scene collider enumeration, collider disable/restore, and collision-state restoration | Not implemented. `SceneManager.GetActiveScene` (`RVA 0x1de17e0`) plus `Scene.GetRootGameObjects` (`0x47068`) can enumerate active-scene roots, and `Component.GetComponentsInChildren<Collider>(bool)` has a generic MethodInfo slot at data RVA `0x2b5f3f0`. However, this exact Unity build exposes `Collider.get_enabled` only (`0x1e11720`); `Collider` derives directly from `Component`, so `Behaviour.set_enabled` cannot be called on it. `Physics.IgnoreCollision(Collider,Collider,bool)` exists (`0x1e12f78`) but no `GetIgnoreCollision` getter exists. A direct `BL` xref shows the game itself calls the two-argument ignore overload in `RootMotion.FinalIK.InteractionEffector.PickUp` at `0x10103dae8`, so blindly restoring every pair to `ignore=false` can undo original item-interaction state. This is a concrete missing reversible setter/state query, not a lack of collider enumeration. Do not substitute Float, kinematic mode, or a global collision-matrix change. |
| Goose resize | Changes Goose `Transform.localScale` incrementally | Transform access and baseline lifecycle | Implemented with a captured per-Goose baseline and 0.5×–2× slider. |
| Goose color randomization | Changes material colors on the Goose | Renderer enumeration, Material color read/write, and restoration | Source-implemented as a touchscreen hue slider. The game-thread helper enumerates at most 32 Goose child renderers, gets each renderer's first material instance, captures its `_Color`, applies the selected hue, and restores the captured color when disabled. Scene replacement resets the per-Goose cache. This is an original implementation; only the first material per renderer is changed. Device rendering and reset behavior are unverified. |
| Goose 2 skin / player icon | Enables named GooseB visual and a named co-op icon object | Requires object lookup, renderer and SpriteRenderer access | Not implemented; this target app is single-player and the relevant scene objects are not resolved. |
| Save/load goose position | Saves Transform position and later restores it | Rigidbody/Transform calls on game thread | Implemented using `Rigidbody.get_position` and `MovePosition`; bounded coordinates and momentum reset. |
| Area teleport list | Eight scene-area coordinates | Physics-thread position command | Implemented through the shared checked teleport dispatcher. |
| Speedrun clip list | Six clip/practice coordinates | Physics-thread position command | Implemented through the shared checked teleport dispatcher. |
| Experimental/out-of-bounds teleports | Nine coordinates, including elevated/outside-map positions | Physics-thread position command with recovery warning | Implemented; menu warns that recovery may require restarting the game. |
| Teleport to bell / boot / child; spawn bell / boot / Timmy | `GameObject.Find(name)` and position changes | Managed string creation, object lookup, ownership and scene lifecycle | Not implemented. `GameObject.Find(string)` is a function entry at `0x101dc3a6c`, but no verified managed-string allocator/bootstrap is present; neither `il2cpp_string_new` nor `il2cpp_object_new` appeared in the stripped executable's symbol/export/string checks. |
| Item relocation and named object spawner | Finds named objects; test spawner can instantiate game objects | Object identity, strings, prefab setup and lifetime | Named game items are not implemented. |
| Experimental primitive creation/destruction | Creates/destroys Unity primitives; upstream buttons select cube/sphere/capsule/cylinder | Direct Unity API calls on game thread | Implemented in the active source: creates one primitive 1.5 units above the Goose and replaces/destroys the previous test primitive. Uses pinned `CreatePrimitive`, `get_transform`, `set_position`, and `Destroy` methods. Device behavior is unverified. |
| Disable NPC shoo | Writes `Body.shooReadiness.timeAllowedToShooAgain` | `Body.Update` hook and field mapping | Implemented through the verified Body.Update hook at body offset `+0x90`; clearing only its sentinel restores normal cooldown progression. |
| NPC resize | Upstream selects named people and adjusts local scale | Per-NPC `Body.Update`, Transform and baseline tracking | Implemented in active source as a bounded all-active-people size slider, using a 32-entry baseline table reset when the Goose Mover changes. Device/transition behavior is unverified. |
| NPC location tracking / ESP | Projects active NPC positions with `Camera.main` and draws red markers | Body hook, camera projection and UIKit render overlay | Implemented in active source: Body.Update position → verified `Camera.WorldToScreenPoint` → pass-through UIKit overlay. Generic labels are used because names are unresolved. Device orientation/coordinate fit is unverified. |
| Disable/remove NPC AI | Not a separate current upstream menu action; the source primarily suppresses shoo | Brain/NavMeshAgent access and restoration if added | Not a current upstream feature. No AI disable control is exposed. |
| Clone/destroy NPCs and Goose | Instantiates selected GameObjects; removes tracked clones | Safe source selection, component cloning, reference lifetime and cleanup | Not implemented. A button is withheld until source selection and stale-object handling are safe. |
| Task completion | Triggers named switch events/task IDs; upstream warns of achievement side effects | Managed strings, progression semantics, save/achievement behavior | Not implemented. `SwitchEventManager.TriggerEvent(string)` is an exact function entry at `0x101146688`, but task IDs, managed-string creation, persistent progression and achievement side effects are not verified. |
| Collider visualization / debug details | Draws collider lines, object information and screen-space output | Collider geometry and a render overlay | NPC marker overlay exists; general collider visualization and native debug inspector remain unimplemented. |
| Wireframe / create-destroy primitives | Changes rendering mode and creates/removes primitives | Renderer-state capture/restore; Unity object creation | Primitive create/remove is implemented. Wireframe is not. |
| First-person Goose camera | Parents a new camera to Goose head and hides Goose render meshes | Existing camera Transform and Goose head Transform | Source-implemented by placing the existing `Goose.cameraTransform` 0.15 world units forward of the verified `Goose.head` Transform and copying head rotation each `GooseCameraHelper.LateUpdate`. It does not create a camera or hide Goose renderers. Visual framing and clipping are unverified on device. |
| Magic/free camera, controls, freeze/reset, position info, teleport Goose to camera, follow distance | Creates another camera, moves it by keyboard/mouse, toggles active camera, reports pose | Existing camera Transform hook and touch controls | Follow-distance multiplier, camera position readout, current-camera Goose teleport, limited world-axis free camera, and first-person camera mode are source-implemented. Free camera freezes the follow update and offers six world-axis touch nudges with configurable step; first-person mode follows the Goose head and rotation. Both reuse the existing camera Transform. Disabling returns to the original follow path. Camera rotation controls and full upstream camera replacement are not implemented. Device/runtime behavior is unverified. |
| Random Bell minigame / marker | Randomizes goldenBell position and shows a marker | Named object lookup, bounded placement and UIKit marker | Not implemented because the bell pointer/name lookup is unresolved. |
| Game speed / slow motion | Changes Unity `Time.timeScale` | Physics-thread Unity Time calls and lifecycle restoration | Implemented as an opt-in bounded 0.5×–2× global rate slider; skips paused time and returns to 1× when disabled during gameplay. |
| Multiplayer Goose-to-Goose actions | Historic GooseNest/multiplayer behavior references GooseB and bell | Requires the single-player build to contain player-two objects | Unsupported by the exact target game build; no multiplayer mode or second Goose pointer is present. |
| Deliberately removed upstream functions | Changelog says third-person was removed for janky movement, “bring all GameObjects to Goose” was removed as game-breaking, and AdvanceOutput was removed | Do not reintroduce by default | Not reintroduced. |

## Current native architecture

- UIKit owns the menu and publishes bounded settings or one-shot commands only. It does not call Unity APIs.
- The existing `Mover.FixedUpdate` hook is the serialized game-thread/physics-thread dispatcher. Its entry, hook word and displaced instruction remain pinned by the existing executable/metadata/UUID checks.
- The original Goose reference and Rigidbody are already live at the verified hook. `Mover.currentSpeed` is at `+0x20`; the helper changes the horizontal velocity generated by the original movement code, rather than multiplying that field and risking compounding or a write racing the game update.
- Position reads and teleports use verified methods from the IL2CPP 24.1 method map: `Rigidbody.get_position` RVA `0x1e16108`, `Rigidbody.MovePosition` RVA `0x1e16454`, and `Rigidbody.set_velocity` RVA `0x1e158fc`. Addresses are patched as same-image relative branches and inherit ASLR slide with the game image.
- Shared data remains in the already-pinned zero-fill state page. It now contains jump, speed, and teleport request state. A command is consumed on the physics thread, validates finite map-bounded coordinates, and clears momentum after an arrival. Scene/player replacement clears pending teleport/save state.
- The menu's full-screen container returns `nil` from UIKit hit testing outside its launcher or visible panel. Multitouch stays enabled, and the separate Jump button remains in place.

## Mission 07 verified API evidence

The following additions are mapped against the exact pinned executable's `LC_FUNCTION_STARTS` and IL2CPP dump; each listed VA is a function entry, not an inferred call-site interior. Base VA is `0x100000000`.

| API / hook | RVA | Use in the active source |
|---|---:|---|
| `GameObject.CreatePrimitive(PrimitiveType)` | `0x1dc3204` | Create one selected test primitive |
| `Rigidbody.get_position` | `0x1e16108` | Anchor primitive at goose position |
| `GameObject.get_transform` | `0x1dc3638` | Position the primitive |
| `Transform.set_position` | `0x1deae6c` | Position the primitive |
| `UnityEngine.Object.Destroy` | `0x1dd344c` | Replace/remove the previous test primitive |
| `Component.get_transform` | `0x1dba100` | Capture/apply active Body scale and position |
| `Transform.get_localScale` / `set_localScale` | `0x1deb834` / `0x1deb8e0` | NPC baseline scaling |
| `Transform.get_position` | `0x1deadc0` | NPC screen-marker input |
| `Camera.get_main` / `WorldToScreenPoint(Vector3)` | `0x1db8128` / `0x1db7a64` | NPC screen projection |
| `Camera.get_main` / `Component.get_transform` / `Transform.get_position` | `0x1db8128` / `0x1dba100` / `0x1deadc0` | Game-thread camera position readout |
| `Screen.get_width` / `get_height` | `0x1de2a24` / `0x1de2a84` | Convert projection to overlay dimensions |
| `Body.Update` hook | `0x107d13c` | Existing shoo guard plus bounded live Body tracking |
| `GooseCameraHelper.LateUpdate` hook | `0x10c8d88` | Free camera: hooks the verified method entry, preserves the exact displaced `sub sp,sp,#0x80`, and branches back to `+4` when disabled or when the camera reference is invalid |
| `GooseCameraHelper.goose` / `Goose.cameraTransform` / `Goose.head` fields | `+0x18` / `+0x238` / `+0x1b0` | Resolve the live camera and head Transforms from the exact IL2CPP type layouts |
| `Transform.get_forward`, `get_rotation`, `set_rotation` | `0x1deb4bc`, `0x1deb098`, `0x1deb698` | First-person camera placement and orientation |
| `Component.GetComponentsInChildren<Renderer>(bool)` shared body / MethodInfo slot | `0x2137cf8` / data RVA `0x2b5f410` | Enumerate Goose child renderers with the original IL2CPP generic context |
| `Renderer.get_sharedMaterial`, `Renderer.get_material`, `Material.GetColor(string)`, `Material.set_color` | `0x1dde6ac`, `0x1dde6a4`, `0x1dc9670`, `0x1dc8640` | Capture, apply, and restore Goose tint per renderer |
| `_Color` runtime string literal slot | data RVA `0x2b8a8a0` | Call `Material.GetColor(string)` without synthesizing a managed string |
| `SceneManager.GetActiveScene`, `Scene.GetRootGameObjects` | `0x1de17e0`, `0x47068` | Enumerate active scene roots for collision research; not used by the shipped helper |
| `Component.GetComponentsInChildren<Collider>(bool)` / MethodInfo slot | `0x2137cf8` / data RVA `0x2b5f3f0` | Generic collider enumeration; slot existence is metadata evidence, not runtime invocation validation |
| `Physics.IgnoreCollision(Collider,Collider,bool)` / known game caller | `0x1e12f78` / `0x10103dae8` | Ignore pair control exists, but the build has no pair-state getter and game interactions already use pair ignores |

The helper calls these entries only from the game-thread `Body.Update`, movement hook, or camera `LateUpdate` hook. UI reads projected coordinates through atomic acquire loads; game code publishes object identity, coordinates and visibility with release stores. The 32-slot registry is bounded and reset when the observed Goose `Mover` changes. This avoids managed enumeration but means NPC markers are generic and only active `Body.Update` objects are represented. Runtime object lifetime, orientation scaling, first-person framing, and visual correctness still need device testing.

## Additional native features in v0.2 source

- Float / Hold Height locks only the Goose Rigidbody Y velocity to zero, leaves X/Z untouched, and does not disable collision or alter Rigidbody gravity configuration. It yields while the Goose is swimming, dragging, or kinematic.
- Game speed is an opt-in, finite 0.5×–2× `Time.timeScale` override. Reads/writes occur from the verified `Mover.FixedUpdate` hook, never UIKit. When disabled, the helper restores 1× after gameplay resumes; it does not call Unity while time is paused.
- Goose size captures the Goose Transform's baseline local scale once per Goose instance and derives every new scale from that baseline. It does not compound per physics frame and returns to the captured scale at 100%.
- Follow camera distance captures the current helper distance and applies a bounded multiplier from the physics hook. When set back to 100%, it restores the captured baseline. This is a zoom/follow-distance control, not a free camera.
- Disable NPC shoo hooks the verified `Body.Update` entry (`0x10107d13c`), preserves its displaced `STP x20,x19,[sp,#-0x20]!`, and branches back to the original function at `+4`. While enabled, it writes the upstream sentinel `100000.0` to the verified shoo cooldown field. On disable it clears only that sentinel; the next normal Body update proceeds. Scene lifecycle and runtime stability still require device verification.
- These additional controls are source-implemented and unit/static validated. Their effects require testing in the new iPhone build.
- First-person mode reuses the existing camera Transform and follows the Goose head Transform at a 0.15-unit forward offset, including head rotation. It is mutually exclusive with free-camera mode and falls back to the original camera update if the Goose or either Transform is null. Whether the camera offset avoids clipping and whether head animation produces acceptable framing require device validation.
- Goose hue uses the IL2CPP `Component.GetComponentsInChildren<Renderer>(bool)` generic MethodInfo slot and `_Color` string-literal slot; it does not construct a managed string or call UIKit from the Unity thread. If the literal has not yet been lazily initialized, the helper triggers Unity's own `Material.set_color` initializer only on a per-renderer material instance that differs from its shared material, then reads the baseline from the untouched shared material. The first material's color is captured and later restored. The fixed cache holds 32 entries, clears on Goose replacement, and needs device checks for material count, visual consistency, and lifecycle restoration.

## Validation boundary

Native/unit tests and Apple SDK compilation validate the command format, input boundaries, and Mach-O component. They do not prove the teleport destinations are correct in the iOS port, that the overlay presents correctly in LiveContainer, or that speed/teleport behavior is stable in gameplay. Those require an iPhone test.
