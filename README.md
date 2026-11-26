# Untitled Goose Game Jump Mod

Version-pinned ARM64 jump helper and UIKit Honk-Menu port for the iOS game, including jump, movement speed, teleport/save/restore, Float/Hold Height, game speed, Goose size, follow-camera distance and NPC shoo suppression. The intended deployment path is **LiveContainer**. The parity matrix distinguishes implemented controls from upstream tools still blocked by unverified Unity object/render access.

The private build repository stores the exact original IPA as a restricted GitHub release asset named `source-ipa`; it is never committed to Git. CI downloads that asset, verifies the original IPA/executable/metadata hashes, compiles the iOS overlay on a macOS runner, patches an isolated copy, validates the IPA, and uploads a private Actions artifact.

Read [HANDOFF.md](HANDOFF.md), [VALIDATION.md](VALIDATION.md), and [LIVECONTAINER_TESTING.md](LIVECONTAINER_TESTING.md) for verified addresses, build state, LiveContainer behavior, and device-test steps.

The source IPA is proprietary. Do not make this repository public or copy the release asset into Git history. Static validation does not prove successful launch or jumping on a device.
