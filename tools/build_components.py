#!/usr/bin/env python3
"""Build redistributable Goose Jump components without accessing game assets."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import subprocess
import sys
from pathlib import Path

import build_ipa

HONK_MENU_ACTIONS = [
    "jump-toggle", "jump-impulse", "horizontal-speed", "float-hold-height",
    "game-speed", "goose-size", "follow-camera-distance", "disable-npc-shoo",
    "npc-size-all-active-bodies", "npc-world-screen-markers", "save-position",
    "camera-position-readout",
    "free-camera-world-axis-move", "teleport-to-current-camera",
    "restore-position", "teleport-to-current-camera", "area-teleport", "practice-teleport",
    "experimental-out-of-bounds-teleport", "spawn-and-replace-unity-primitive",
    "destroy-last-primitive",
]


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(argv: list[str], *, capture: bool = False) -> str:
    result = subprocess.run(argv, check=True, text=True,
                            stdout=subprocess.PIPE if capture else None)
    return result.stdout if capture else ""


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=Path("build"))
    parser.add_argument("--impulse", type=float, default=2.5)
    parser.add_argument("--commit", default=os.environ.get("GITHUB_SHA", "local"))
    parser.add_argument("--run-id", default=os.environ.get("GITHUB_RUN_ID", "local"))
    parser.add_argument("--run-attempt", default=os.environ.get("GITHUB_RUN_ATTEMPT", "1"))
    parser.add_argument("--xcode", default="xcodebuild")
    parser.add_argument("--otool", default="xcrun")
    parser.add_argument("--clang", default="clang")
    parser.add_argument("--ld", default="ld.lld")
    parser.add_argument("--objcopy", default="llvm-objcopy")
    parser.add_argument("--nm", default="llvm-nm")
    args = parser.parse_args()
    for name, value in (("impulse", args.impulse),):
        if not math.isfinite(value) or value <= 0 or value > 100:
            raise SystemExit(f"{name} must be finite and in (0, 100]")

    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    dylib = out / "GooseJump.dylib"
    helper_path = out / "jump_helper.bin"
    sdk_path = run(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], capture=True).strip()
    run(["xcrun", "--sdk", "iphoneos", "clang++", "-std=c++17", "-arch", "arm64", "-fobjc-arc",
         "-dynamiclib", "-miphoneos-version-min=15.0", "-isysroot", sdk_path,
         f"-DGOOSE_JUMP_IMPULSE={args.impulse}f",
         str(build_ipa.ROOT / "src/JumpOverlay.mm"),
         str(build_ipa.ROOT / "src/HonkMenuOverlay.mm"), "-framework", "Foundation",
         "-framework", "UIKit", "-framework", "QuartzCore", "-framework", "CoreGraphics",
         "-Wl,-undefined,error",
         f"-Wl,-install_name,{build_ipa.DYLIB_INSTALL_NAME}", "-o", str(dylib)])
    dylib_bytes = dylib.read_bytes()
    build_ipa.validate_dylib(dylib_bytes)

    with __import__("tempfile").TemporaryDirectory(prefix="goose-jump-component-helper-") as temp:
        helper = build_ipa.make_helper(Path(temp), args.clang, args.ld,
                                       args.objcopy, args.nm)
    if len(helper) < 16 or len(helper) > build_ipa.CODE_END_VA - build_ipa.HELPER_VA:
        raise ValueError("built ARM64 helper has an invalid size")
    if int.from_bytes(helper[12:16], "little") != build_ipa.HOOK_ORIGINAL:
        raise ValueError("built helper does not replay the expected displaced instruction")
    helper_path.write_bytes(helper)

    load_info = run(["xcrun", "--sdk", "iphoneos", "otool", "-L", str(dylib)], capture=True)
    for framework in ("Foundation.framework/Foundation", "UIKit.framework/UIKit",
                      "QuartzCore.framework/QuartzCore", "CoreGraphics.framework/CoreGraphics"):
        if framework not in load_info:
            raise ValueError(f"compiled dylib is missing expected dependency {framework}")
    if "libc++.1.dylib" not in load_info:
        raise ValueError("compiled Objective-C++ dylib is missing the iOS C++ runtime dependency")
    if "Simulator" in load_info or "iPhoneSimulator" in load_info:
        raise ValueError("simulator-only dependency found in iPhoneOS dylib")
    symbols = run(["xcrun", "--sdk", "iphoneos", "nm", "-gU", str(dylib)], capture=True)
    for class_name in ("GooseJumpOverlay", "HonkMenuOverlay"):
        if class_name not in symbols:
            raise ValueError(f"compiled dylib is missing the {class_name} Objective-C class symbols")

    version = run([args.xcode, "-version"], capture=True).strip()
    manifest = {
        "schema": 2,
        "source_commit": args.commit,
        "workflow_run_id": str(args.run_id),
        "workflow_run_attempt": str(args.run_attempt),
        "target": "arm64-apple-ios15.0",
        "platform": "iPhoneOS",
        "sdk_path": sdk_path,
        "xcode": version,
        "host_architecture": platform.machine(),
        "jump_impulse": args.impulse,
        "native_honk_menu": True,
        "honk_menu_actions": HONK_MENU_ACTIONS,
        "helper_file": helper_path.name,
        "helper_sha256": digest(helper_path),
        "helper_size": len(helper),
        "dylib_file": dylib.name,
        "dylib_sha256": digest(dylib),
        "dylib_size": len(dylib_bytes),
        "dylib_install_name": build_ipa.DYLIB_INSTALL_NAME,
        "dylib_load_dependencies": [line.strip() for line in load_info.splitlines()[1:] if line.strip()],
        "dylib_exported_symbols": [line.strip() for line in symbols.splitlines()
                                    if "GooseJumpOverlay" in line or "HonkMenuOverlay" in line],
    }
    manifest_path = out / "build-info.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    sums = out / "SHA256SUMS.txt"
    sums.write_text("".join(f"{digest(path)}  {path.name}\n"
                            for path in (helper_path, dylib, manifest_path)))
    print(json.dumps(manifest, indent=2))
    print(load_info)
    print(symbols)


if __name__ == "__main__":
    main()
