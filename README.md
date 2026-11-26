# Goose Jump iOS source and component builder

This public repository contains the version-pinned ARM64 jump helper, original UIKit jump/menu overlays, patcher source, tests, and macOS build workflow. It contains no Untitled Goose Game IPA, executable, Unity assets, or modified game package.

The public GitHub Actions workflow compiles and publishes only these redistributable components:

- `GooseJump.dylib`, built for arm64 iPhoneOS with the iOS SDK
- `jump_helper.bin`, assembled and linked from `src/jump_helper.S`
- the native Honk-Menu compatibility UI and movement/teleport command bridge
- `build-info.json` and `SHA256SUMS.txt`

The actual game IPA is kept separately in a private repository. Final game packaging is performed locally with that private source and `tools/build_ipa.py`; a game IPA must never be uploaded to this public repository, its releases, or its Actions artifacts.

See [BUILD_PUBLIC.md](BUILD_PUBLIC.md) for the CI artifact and local packaging boundary, [DESIGN.md](DESIGN.md) for the patch architecture, and [LIVECONTAINER_TESTING.md](LIVECONTAINER_TESTING.md) for runtime assumptions and device testing. Static checks do not establish successful LiveContainer launch or in-game jumping.

The Honk-Menu feature inventory and iOS port status are documented in [HONK_MENU_PARITY.md](HONK_MENU_PARITY.md). The upstream repository has no declared license; its code and artwork are not copied here. The native interface is a clean implementation informed by feature descriptions and verified game interfaces.
