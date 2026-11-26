# LiveContainer import and device test

## Runtime model used by this build

LiveContainer does not start the guest IPA as a normal SpringBoard app. Its loader rewrites the guest executable to a loadable image, adjusts `__PAGEZERO`, injects its own `TweakLoader.dylib`, changes `@executable_path` handling to point at the guest bundle, and enters the guest app's `UIApplicationMain`. The patch preserves the original guest UUID and uses it to find the correct image and ASLR slide. The Jump overlay resolves the guest image's data and Unity method addresses relative to that slide; it does not assume the host is image 0.

The injected library lives at `Payload/untitledgooseport.app/Frameworks/GooseJump.dylib`; the executable dependency and dylib install name both use `@executable_path/Frameworks/GooseJump.dylib`, which LiveContainer redirects to the guest app bundle. The button attaches through the guest `UnityAppController` window and avoids LiveContainer's host key window.

LiveContainer documentation says that, below iOS 26, a successfully enabled JIT can bypass guest code-signature/library-validation checks; without JIT, LiveContainer signs the guest using its imported AltStore/SideStore certificate. JIT does not itself repair bad Mach-O commands or wrong library paths. On iOS 26 and later, some A15/M2-or-newer devices also require a per-app JIT script. See the [LiveContainer loader overview](https://github.com/LiveContainer/LiveContainer#how-does-it-work), [architecture guide](https://livecontainer.github.io/docs/development/architecture), and [JIT support guide](https://livecontainer.github.io/docs/guides/jit-support).

This IPA is intentionally unsigned for LiveContainer. Do not re-sign it through a separate sideloading flow before import. LiveContainer may apply its own signing behavior depending on iOS/JIT configuration. The build has not yet been imported or tested on a physical iPhone.

## Get and transfer the private IPA

1. Sign into GitHub and open the private [`jump-mod-v0.2.0` release](https://github.com/LawrenceBanes/goose-jump-ios/releases/tag/jump-mod-v0.2.0).
2. Download `UntitledGooseGame-JumpMod-v0.2.0-LiveContainer.ipa`. Its SHA-256 is `38588b44dd039389a844f09d7a14be3adb600361b474b6df201c941a9f62e3a9` (374,956,903 bytes).
3. Verify the downloaded file's SHA-256 before transfer.
4. Transfer it to the iPhone using Files, AirDrop, or another trusted local transfer method.

The original 355 MiB IPA remains a separate private release input. It is not part of the public repository or its Actions artifact.

## Import and configure LiveContainer

1. In LiveContainer, tap **+** and select the modified IPA.
2. Select the imported Goose game entry to launch it. Keep the existing LiveContainer installation and its data intact.
3. In the app's long-press settings, enable **Launch with JIT** if your configured JIT provider supports the device.
4. Confirm LiveContainer can enable JIT for this guest. On iOS 26+ with supported newer devices, select the required per-app JIT script as described in LiveContainer's guide.
5. Launch the game. Do not install the guest as a standalone app.

If JIT cannot be enabled, LiveContainer may require its certificate import/signing configuration to launch guest binaries. That signing is handled by LiveContainer's runtime, not by this build pipeline.

## Focused test checklist

Record the iPhone model, iOS version, LiveContainer version, JIT provider, and whether the guest was launched with JIT. If it crashes, collect the LiveContainer guest error and a device crash log; a screen recording is useful for button/layout and jump behavior.

1. Import the IPA and launch. Confirm LiveContainer does not report a Mach-O, signature, dependency, or missing-library error.
2. Confirm Unity initializes and the title screen appears; navigate into gameplay.
3. Confirm the **Jump** button is visible over the game view and not on the LiveContainer host UI.
4. Move with the joystick; test running, honking, grabbing/releasing, and camera controls.
5. Tap Jump on flat ground. Confirm takeoff, gravity-driven landing, and continued horizontal movement.
6. Keep the joystick held with one finger and tap Jump with a second finger. Confirm both controls register and releasing either finger does not cancel the other.
7. Tap Jump during ascent, apex, and descent. Each distinct tap should add another upward impulse; holding Jump should not auto-repeat.
8. Test swimming, grabbing/dragging, pause/resume, scene transition, and game restart.
9. Test both landscape orientations and safe-area edges. Report any overlap with the existing mobile buttons.

The user confirmed v0.1.0 jumping on-device. Do not report v0.2.0 multitouch or air-jump behavior as successful until this version is observed on-device.

## Honk-Menu iOS device test checklist

Import the private `honk-menu-ios-v0.2.0` release linked below for the current feature set. CI and package validation are complete; newly added feature behavior remains unverified.

1. Tap the **HM** launcher. Confirm the panel fits in both landscape orientations and does not cover the existing movement/honk/grab controls.
2. With the menu closed, touch outside the HM launcher and Jump button; confirm those touches still reach the game. Open the menu and test its controls with more than one finger.
3. Toggle **Jump modification** off and on. Confirm off prevents Jump impulses and on restores existing v0.2 air-jump behavior. Adjust impulse and verify it persists after closing/reopening the game.
4. Adjust **Horizontal speed** below and above 100%; check that direction, normal movement controls, and vertical jump physics remain intact. Restore to 100% afterward.
5. Save Goose position, walk away, then restore. Confirm the goose returns and momentum clears without dropping through or clipping world collision.
6. Test the eight area destinations and six speedrun clip locations individually. Test out-of-bounds destinations only after a manual save and be ready to use the game's restart; these destinations are intentionally experimental.
7. Pause while a menu action is pending, background/resume the app, and change scenes. Confirm stale actions do not execute later.
8. True Noclip, free/first-person camera, NPC tracking/manipulation, item spawning, and task completion remain unavailable; those rows are explicitly marked as unavailable. Follow-camera distance and Disable NPC shoo have native controls and are covered in the v0.2.0 checklist below.

### Honk-Menu v0.1.0 release

Private release: [honk-menu-ios-v0.1.0](https://github.com/LawrenceBanes/goose-jump-ios/releases/tag/honk-menu-ios-v0.1.0). Download `UntitledGooseGame-HonkMenu-iOS-v0.1.0-LiveContainer.ipa` and its `.sha256` sidecar while authenticated to GitHub. Verify the checksum before transfer. Import using LiveContainer's **+** picker; retain v0.1.0 as a rollback for v0.2.0. The v0.1 menu features were later reported working by the user.


### Honk-Menu v0.2 controls

- Test **Float / hold height** while on a safe flat area. Confirm vertical drift stops, horizontal joystick movement stays responsive, Goose does not pass through collision, and the feature yields when swimming or dragging. Turn it off and confirm gravity resumes.
- Enable **Custom game speed**, try 0.5×, 1× and 2×, then disable it and confirm normal 1× speed returns. Test pause/resume and scene transition; do not change the slider while paused.
- Test **Goose size** at 50%, 100% and 200%. Confirm the original size returns at 100%, change is stable across repeated updates, and scene/game restart does not accumulate scale.
- These controls are source-implemented but need real-device verification. True noclip remains unavailable and collision should remain active.

## Honk-Menu v0.2.0 additions

Download `UntitledGooseGame-HonkMenu-iOS-v0.2.0-LiveContainer.ipa` from the private [honk-menu-ios-v0.2.0 release](https://github.com/LawrenceBanes/goose-jump-ios/releases/tag/honk-menu-ios-v0.2.0), and verify it against the attached `.ipa.sha256` file. Import the unsigned IPA through LiveContainer's **+** picker and enable the supported **Launch with JIT** option. Keep v0.1.0 available as rollback. Do not use a separate SideStore signing process for this release.

The v0.1 Honk-Menu gameplay has user-reported success. These v0.2 additions are not confirmed on-device yet:

1. Open **HM → Move**. Check for `Float / hold height`, `Custom game speed`, `Goose size`, and `Follow camera distance`; test them and return sliders to 100% afterward.
2. Under **HM → Goose/NPC**, toggle `Disable NPC shoo` on and off. Check NPC shoo behavior is suppressed while enabled and resumes after disabling.
3. Test while running, swimming, grabbing/dragging, paused, and through scene change/restart. Watch camera framing, NPC behavior, Goose scale, movement, and pause/resume.
4. Retest jump, joystick multitouch, honk, grab/release, built-in pause/goals, and touch pass-through.

## Mission 07 unreleased source features

The in-progress source adds Unity primitive spawn/remove, NPC resizing, NPC position markers, a camera-position readout, teleport-to-current-follow-camera, and a limited free camera. These changes are not in any release yet. Once a validated IPA exists, test each primitive button and clear action, then verify repeated use and scene changes do not leave stale objects. Test NPC scale at 50%, 100%, and 200%; confirm returning to 100% restores each person’s original size. Enable tracking and check marker alignment in both landscape orientations, camera movement, occlusion/depth behavior, and pause/scene transitions. Check the camera coordinate readout, save Goose position, and try camera teleport in a safe open area. Toggle Free camera and use all six world-axis nudge buttons; confirm the camera stops following, the configured step changes movement, disabling restores follow behavior, and background/resume or scene transition does not leave it frozen. Camera rotation is fixed in this implementation. Report crashes and provide a screen recording if markers drift or camera state is not restored.

Report device model, iOS/LiveContainer version, JIT status, launch result, per-feature behavior, and any crash log or screen recording if a test fails.
