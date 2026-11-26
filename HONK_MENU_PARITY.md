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
| Noclip | Disables goose colliders and uses free movement | Requires verified Goose/world collider pairing and restoration | Not implemented. `UnityEngine.Collider` in this build exposes `get_enabled` only. Safe `Physics.IgnoreCollision` would require complete live collider enumeration; native generic enumeration/type descriptors are not yet wired. Do not substitute Float or kinematic mode. |
| Goose resize | Changes Goose `Transform.localScale` incrementally | Transform access and baseline lifecycle | Implemented with a captured per-Goose baseline and 0.5×–2× slider. |
| Goose color randomization | Changes material colors on the Goose | Renderer/material access and original material-state capture | Not implemented; renderer and material arrays are not yet safely resolved. |
| Goose 2 skin / player icon | Enables named GooseB visual and a named co-op icon object | Requires object lookup, renderer and SpriteRenderer access | Not implemented; this target app is single-player and the relevant scene objects are not resolved. |
| Save/load goose position | Saves Transform position and later restores it | Rigidbody/Transform calls on game thread | Implemented using `Rigidbody.get_position` and `MovePosition`; bounded coordinates and momentum reset. |
| Area teleport list | Eight scene-area coordinates | Physics-thread position command | Implemented through the shared checked teleport dispatcher. |
| Speedrun clip list | Six clip/practice coordinates | Physics-thread position command | Implemented through the shared checked teleport dispatcher. |
| Experimental/out-of-bounds teleports | Nine coordinates, including elevated/outside-map positions | Physics-thread position command with recovery warning | Implemented; menu warns that recovery may require restarting the game. |
| Teleport to bell / boot / child; spawn bell / boot / Timmy | `GameObject.Find(name)` and position changes | Managed string creation, object lookup, ownership and scene lifecycle | Not implemented. Exact `GameObject.Find(string)` exists at RVA `0x1dc3a6c`, but no safe managed-string creation/lookup service is integrated. |
| Item relocation and named object spawner | Finds named objects; test spawner can instantiate game objects | Object identity, strings, prefab setup and lifetime | Named game items are not implemented. |
| Experimental primitive creation/destruction | Creates/destroys Unity primitives; upstream buttons select cube/sphere/capsule/cylinder | Direct Unity API calls on game thread | Implemented in the active source: creates one primitive 1.5 units above the Goose and replaces/destroys the previous test primitive. Uses pinned `CreatePrimitive`, `get_transform`, `set_position`, and `Destroy` methods. Device behavior is unverified. |
| Disable NPC shoo | Writes `Body.shooReadiness.timeAllowedToShooAgain` | `Body.Update` hook and field mapping | Implemented through the verified Body.Update hook at body offset `+0x90`; clearing only its sentinel restores normal cooldown progression. |
| NPC resize | Upstream selects named people and adjusts local scale | Per-NPC `Body.Update`, Transform and baseline tracking | Implemented in active source as a bounded all-active-people size slider, using a 32-entry baseline table reset when the Goose Mover changes. Device/transition behavior is unverified. |
| NPC location tracking / ESP | Projects active NPC positions with `Camera.main` and draws red markers | Body hook, camera projection and UIKit render overlay | Implemented in active source: Body.Update position → verified `Camera.WorldToScreenPoint` → pass-through UIKit overlay. Generic labels are used because names are unresolved. Device orientation/coordinate fit is unverified. |
| Disable/remove NPC AI | Not a separate current upstream menu action; the source primarily suppresses shoo | Brain/NavMeshAgent access and restoration if added | Not a current upstream feature. No AI disable control is exposed. |
| Clone/destroy NPCs and Goose | Instantiates selected GameObjects; removes tracked clones | Safe source selection, component cloning, reference lifetime and cleanup | Not implemented. A button is withheld until source selection and stale-object handling are safe. |
| Task completion | Triggers named switch events/task IDs; upstream warns of achievement side effects | Managed strings, progression semantics, save/achievement behavior | Not implemented. `SwitchEventManager.TriggerEvent(string)` is mapped, but task IDs and persistent progression effects are not verified. |
| Collider visualization / debug details | Draws collider lines, object information and screen-space output | Collider geometry and a render overlay | NPC marker overlay exists; general collider visualization and native debug inspector remain unimplemented. |
| Wireframe / create-destroy primitives | Changes rendering mode and creates/removes primitives | Renderer-state capture/restore; Unity object creation | Primitive create/remove is implemented. Wireframe is not. |
| First-person Goose camera | Parents a new camera to Goose head and hides Goose render meshes | Camera/render lifecycle, component access and renderer restoration | Not implemented. |
| Magic/free camera, controls, freeze/reset, position info, teleport Goose to camera, follow distance | Creates another camera, moves it by keyboard/mouse, toggles active camera, reports pose | Camera object discovery/creation, frame-phase hook and touch controls | Follow-distance multiplier is implemented using GooseCameraHelper. Free camera and camera teleport remain unimplemented; camera position display is not yet exposed. |
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
| `Screen.get_width` / `get_height` | `0x1de2a24` / `0x1de2a84` | Convert projection to overlay dimensions |
| `Body.Update` hook | `0x10c8d88` | Existing shoo guard plus bounded live Body tracking |

The helper calls these entries only from the game-thread `Body.Update` or movement hook. UI reads projected coordinates through atomic acquire loads; game code publishes object identity, coordinates and visibility with release stores. The 32-slot registry is bounded and reset when the observed Goose `Mover` changes. This avoids managed enumeration but means NPC markers are generic and only active `Body.Update` objects are represented. Runtime object lifetime, orientation scaling, and visual correctness still need device testing.

## Additional native features in v0.2 source

- Float / Hold Height locks only the Goose Rigidbody Y velocity to zero, leaves X/Z untouched, and does not disable collision or alter Rigidbody gravity configuration. It yields while the Goose is swimming, dragging, or kinematic.
- Game speed is an opt-in, finite 0.5×–2× `Time.timeScale` override. Reads/writes occur from the verified `Mover.FixedUpdate` hook, never UIKit. When disabled, the helper restores 1× after gameplay resumes; it does not call Unity while time is paused.
- Goose size captures the Goose Transform's baseline local scale once per Goose instance and derives every new scale from that baseline. It does not compound per physics frame and returns to the captured scale at 100%.
- Follow camera distance captures the current helper distance and applies a bounded multiplier from the physics hook. When set back to 100%, it restores the captured baseline. This is a zoom/follow-distance control, not a free camera.
- Disable NPC shoo hooks the verified `Body.Update` entry (`0x10107d13c`), preserves its displaced `STP x20,x19,[sp,#-0x20]!`, and branches back to the original function at `+4`. While enabled, it writes the upstream sentinel `100000.0` to the verified shoo cooldown field. On disable it clears only that sentinel; the next normal Body update proceeds. Scene lifecycle and runtime stability still require device verification.
- These additional controls are source-implemented and unit/static validated. Their effects require testing in the new iPhone build.

## Validation boundary

Native/unit tests and Apple SDK compilation validate the command format, input boundaries, and Mach-O component. They do not prove the teleport destinations are correct in the iOS port, that the overlay presents correctly in LiveContainer, or that speed/teleport behavior is stable in gameplay. Those require an iPhone test.
