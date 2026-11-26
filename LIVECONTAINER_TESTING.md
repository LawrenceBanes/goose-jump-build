# LiveContainer import and device test

## Runtime model used by this build

LiveContainer does not start the guest IPA as a normal SpringBoard app. Its loader rewrites the guest executable to a loadable image, adjusts `__PAGEZERO`, injects its own `TweakLoader.dylib`, changes `@executable_path` handling to point at the guest bundle, and enters the guest app's `UIApplicationMain`. The patch preserves the original guest UUID and uses it to find the correct image and ASLR slide. The Jump overlay resolves the guest image's data and Unity method addresses relative to that slide; it does not assume the host is image 0.

The injected library lives at `Payload/untitledgooseport.app/Frameworks/GooseJump.dylib`; the executable dependency and dylib install name both use `@executable_path/Frameworks/GooseJump.dylib`, which LiveContainer redirects to the guest app bundle. The button attaches through the guest `UnityAppController` window and avoids LiveContainer's host key window.

LiveContainer documentation says that, below iOS 26, a successfully enabled JIT can bypass guest code-signature/library-validation checks; without JIT, LiveContainer signs the guest using its imported AltStore/SideStore certificate. JIT does not itself repair bad Mach-O commands or wrong library paths. On iOS 26 and later, some A15/M2-or-newer devices also require a per-app JIT script. See the [LiveContainer loader overview](https://github.com/LiveContainer/LiveContainer#how-does-it-work), [architecture guide](https://livecontainer.github.io/docs/development/architecture), and [JIT support guide](https://livecontainer.github.io/docs/guides/jit-support).

This IPA is intentionally unsigned for LiveContainer. Do not re-sign it through a separate sideloading flow before import. LiveContainer may apply its own signing behavior depending on iOS/JIT configuration. The build has not yet been imported or tested on a physical iPhone.

## Get and transfer the artifact

1. After a successful macOS workflow run exists, open the private `goose-jump-ios` repository's Actions page and download its `untitled-goose-jump-livecontainer` artifact. As of the current checkpoint, the macOS job has not started because of a GitHub account billing/spending restriction, so no IPA artifact is available yet.
2. Extract the Actions artifact ZIP. It contains `UntitledGooseGame-JumpMod-LiveContainer-unsigned.ipa` and `SHA256SUMS.txt`.
3. Verify the IPA checksum against `SHA256SUMS.txt`.
4. Transfer the IPA to the iPhone using Files, AirDrop, or another trusted local transfer method.

The original 355 MiB IPA is retained as a private release input. It is not inside the Actions artifact.

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
6. Tap during ascent, apex, and descent. Confirm no midair retrigger; after landing and cooldown, jump again.
7. Test swimming, grabbing/dragging, pause/resume, scene transition, and game restart.
8. Test both landscape orientations and safe-area edges. Report any overlap with the existing mobile buttons.

Do not report a successful jump until it is observed on-device.
