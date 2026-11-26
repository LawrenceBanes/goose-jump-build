# Honk-Menu iOS parity

## Reference and reuse boundary

- Reference: [xZeko-SRC/Honk-Menu](https://github.com/xZeko-SRC/Honk-Menu), default-branch commit `6ba124e85d79dbbc6658d88e63f89019c0c2b7d3`.
- The isolated checkout is `reference/Honk-Menu/` and is ignored by Git.
- The repository has no `LICENSE` file and GitHub reports no recognized license. Its C# implementation and artwork are therefore not copied into this project or the public build repository. The upstream feature descriptions and numeric practice destinations are used as behavioral references; the iOS code and interface are original.
- Upstream dependencies include MelonLoader, Harmony, Mono.Cecil, Assembly-CSharp and UnityEngine managed assemblies. This Windows/.NET Framework 4.8 plugin is not an iOS-compatible IL2CPP component and is not loaded by the port.

## Feature inventory

| Upstream feature | Actual behavior observed in source | Classification for iOS | Honk-Menu iOS v0.2.0 status |
|---|---|---|---|
| Main menu, categories, shortcuts, credits | Unity IMGUI windows and keyboard shortcut handling | Directly adaptable UI; implementation must be native UIKit | Native touch menu shell; Movement, Teleport, Camera, Goose/NPC, World and Experimental pages. Shows explicit unavailability for incomplete groups. |
| Jump and jump strength | Toggles jump input and uses the Goose Rigidbody path | Requires native IL2CPP movement hook | Implemented by the jump hook; retained with enable switch and impulse slider. |
| Goose speed | Repeatedly changes `Mover.currentSpeed` while a keyboard toggle is active | Requires native movement hook | Implemented as bounded horizontal velocity scaling at the verified Mover physics hook. |
| Save/load goose position | Saves the goose Transform position and sets it back later | Requires native Rigidbody/Transform calls on the game thread | Implemented with verified `Rigidbody.get_position` and `Rigidbody.MovePosition` method pointers; runtime remains device-unverified. |
| Area teleport destinations | Calls `GameObject.Find("Goose").transform.position = ...` using eight coordinates | Requires native movement hook; exact game thread and coordinate validity matter | Eight area destinations are sent as bounded requests and applied through Rigidbody.MovePosition. |
| Speedrun clip destinations | Directly assigns goose Transform position for six named practice locations | Requires native movement hook | Six clip destinations are implemented through the same validated teleport dispatcher. |
| Fun/out-of-bounds destinations | Directly assigns Transform positions, several above/outside the map | Requires native movement hook and carries recovery risk | Nine destinations are available in the scrollable Teleport page with an explicit warning. |
| Noclip / floating | Toggles noclip, disables Goose colliders, and changes movement based on keyboard/controller input | Requires verified collider enumeration, original-state capture/restore and a game-thread movement path | True noclip remains unavailable: this exact build has no verified reversible Collider setter. A separate Float/Hold Height toggle is implemented; it zeroes only Goose vertical velocity on the physics hook, preserves horizontal velocity and collision, and yields while swimming or dragging. |
| Goose color / P2 skin / player icon | Mutates Goose materials, mesh state and a named scene GameObject/SpriteRenderer | Requires IL2CPP renderer/object mapping and resource lifecycle handling | Goose resize is implemented through verified Transform localScale access with a captured baseline and 0.5×–2× bounded slider. Goose color, P2 skin and player icon remain unavailable. |
| Disable shoo | Finds named NPC Brain objects and writes `timeAllowedToShooAgain` | Requires a verified per-NPC update hook and field layout | Implemented through a second verified `Body.Update` entry hook. It writes the known `Body.shooReadiness.timeAllowedToShooAgain` field at `Body + 0x90` to 100000 while enabled, then clears only that sentinel when disabled. Runtime behavior still needs an iPhone test. |
| NPC tracking / ESP | Finds named NPC objects and projects world positions with `Camera.main`/IMGUI | Requires native object lookup, camera calls and render-thread overlay | Not implemented; requires verified object and camera access. |
| NPC/Goose resize and player swap | Finds named objects and changes local scale or position | Requires game-object access plus original transform capture | Not implemented. |
| Speedrun item rescue (bell, boot, child) | Finds named scene objects and moves them to the goose | Requires verified Unity string/object lookup and target identity | Not implemented; the current game-object access service is deliberately limited to the Goose already supplied by `Mover.FixedUpdate`. |
| Item spawner | Finds named GameObjects and moves an item, or creates primitives in the experimental version | Requires Unity object construction, name/string calls and lifetime management | Not implemented. |
| Task completion | Writes a list of task IDs through game task APIs; README warns about achievement effects | Requires verified progression state and save/achievement semantics | Not implemented; excluded to avoid damaging progress or achievement state. |
| Clone/destroy people or Goose | Creates/copies Unity GameObjects and destroys objects | Requires allocation, component cloning and ownership-safe teardown | Not implemented. |
| Wireframe / collider visualization | Changes renderer mode or draws collider boundaries through Unity GUI | Requires graphics/render-thread integration beyond the movement hook | Not implemented. |
| Free camera / first-person camera / goose-to-camera | Creates a Unity camera, adds mouse-look components, hides Goose meshes and handles desktop cursor/input | Mouse, keyboard, cursor locking and managed component creation are unsupported on this iOS path | Not implemented. A UIKit camera control still needs a verified camera rig and render-phase lifecycle hook. The existing follow camera distance can be adjusted separately. |
| Follow camera distance | Uses the Goose camera helper's follow distance | Requires verified camera helper access | Implemented as a bounded 0.5×–2× slider using `Goose.gooseCameraHelper` and `GooseCameraHelper.distance`, with per-helper baseline capture. The slider is under Move → Camera. |
| Game speed / slow motion | Changes Unity time scale from desktop keyboard controls | Requires game-thread Time API call and coordinated input/physics behavior | Implemented as an opt-in 0.5×–2× Time.timeScale slider, applied only from the physics thread; it skips paused state and resets to 1× when disabled. This is a global game-rate change. |
| Random bell minigame | Moves the golden bell to a randomized world position and draws a marker | Requires object lookup, random placement and HUD rendering | Not implemented. |
| Multiplayer Goose-to-Goose actions | Moves Goose/GooseB or bell between players | Depends on the multiplayer scene and two-player objects | Not implemented; current target build is single-player and no second Goose pointer is verified. |

## Current native architecture

- UIKit owns the menu and publishes bounded settings or one-shot commands only. It does not call Unity APIs.
- The existing `Mover.FixedUpdate` hook is the serialized game-thread/physics-thread dispatcher. Its entry, hook word and displaced instruction remain pinned by the existing executable/metadata/UUID checks.
- The original Goose reference and Rigidbody are already live at the verified hook. `Mover.currentSpeed` is at `+0x20`; the helper changes the horizontal velocity generated by the original movement code, rather than multiplying that field and risking compounding or a write racing the game update.
- Position reads and teleports use verified methods from the IL2CPP 24.1 method map: `Rigidbody.get_position` RVA `0x1e16108`, `Rigidbody.MovePosition` RVA `0x1e16454`, and `Rigidbody.set_velocity` RVA `0x1e158fc`. Addresses are patched as same-image relative branches and inherit ASLR slide with the game image.
- Shared data remains in the already-pinned zero-fill state page. It now contains jump, speed, and teleport request state. A command is consumed on the physics thread, validates finite map-bounded coordinates, and clears momentum after an arrival. Scene/player replacement clears pending teleport/save state.
- The menu's full-screen container returns `nil` from UIKit hit testing outside its launcher or visible panel. Multitouch stays enabled, and the separate Jump button remains in place.

## Additional native features in v0.2 source

- Float / Hold Height locks only the Goose Rigidbody Y velocity to zero, leaves X/Z untouched, and does not disable collision or alter Rigidbody gravity configuration. It yields while the Goose is swimming, dragging, or kinematic.
- Game speed is an opt-in, finite 0.5×–2× `Time.timeScale` override. Reads/writes occur from the verified `Mover.FixedUpdate` hook, never UIKit. When disabled, the helper restores 1× after gameplay resumes; it does not call Unity while time is paused.
- Goose size captures the Goose Transform's baseline local scale once per Goose instance and derives every new scale from that baseline. It does not compound per physics frame and returns to the captured scale at 100%.
- Follow camera distance captures the current helper distance and applies a bounded multiplier from the physics hook. When set back to 100%, it restores the captured baseline. This is a zoom/follow-distance control, not a free camera.
- Disable NPC shoo hooks the verified `Body.Update` entry (`0x10107d13c`), preserves its displaced `STP x20,x19,[sp,#-0x20]!`, and branches back to the original function at `+4`. While enabled, it writes the upstream sentinel `100000.0` to the verified shoo cooldown field. On disable it clears only that sentinel; the next normal Body update proceeds. Scene lifecycle and runtime stability still require device verification.
- These additional controls are source-implemented and unit/static validated. Their effects require testing in the new iPhone build.

## Validation boundary

Native/unit tests and Apple SDK compilation validate the command format, input boundaries, and Mach-O component. They do not prove the teleport destinations are correct in the iOS port, that the overlay presents correctly in LiveContainer, or that speed/teleport behavior is stable in gameplay. Those require an iPhone test.
