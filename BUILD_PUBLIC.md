# Public component build

## GitHub Actions

`Build Goose Jump components (source only)` runs on the standard `macos-15` hosted runner. It requires Xcode's iPhoneOS SDK and installs LLVM with Homebrew. It compiles the Objective-C++ overlay for arm64 iPhoneOS, builds the fixed-address helper, checks Mach-O platform/architecture/install name, linked UIKit/Foundation dependencies and exported Objective-C class symbols, and runs the source-only applicable tests.

The workflow rejects IPA files and files larger than 20 MiB in the checkout. Its artifact contains only the dylib, helper, build manifest, and checksums. It never downloads game assets. Source-app audit and patch/package regression tests are marked skipped when private game files are absent; those tests run in the private local workspace where the pinned original is present.

Download the `goose-jump-components-<commit>` artifact from a successful run. Verify its included `SHA256SUMS.txt`; compare `build-info.json.source_commit` and `.workflow_run_id` to the run metadata before using it. The private workspace's patcher also rebuilds the helper and rejects any byte mismatch.

## Final IPA packaging boundary

The public workflow does not package or publish a game IPA. Local packaging requires the original IPA with SHA-256 `70b1cc33d2f6f753113f9801a0ffffa27245796676052121968d26c355f78593`, an extracted matching executable/metadata, the public CI component artifact, and the hash-pinned patcher. Publish the completed IPA only to the existing private `goose-jump-ios` release, after full archive validation.
