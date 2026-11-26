from __future__ import annotations

import struct
import tempfile
import sys
import zipfile
import plistlib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import build_ipa as build


def ios_test_dylib(platform=build.PLATFORM_IOS, install_name=build.DYLIB_INSTALL_NAME):
    encoded = install_name.encode() + b"\0"
    cmdsize = (24 + len(encoded) + 7) & ~7
    id_cmd = struct.pack("<IIIIII", build.LC_ID_DYLIB, cmdsize, 24, 0, 0x10000, 0x10000)
    id_cmd += encoded.ljust(cmdsize - 24, b"\0")
    build_cmd = struct.pack("<IIIIII", build.LC_BUILD_VERSION, 24, platform, 0x000F0000, 0x00120000, 0)
    sizeofcmds = len(id_cmd) + len(build_cmd)
    header = struct.pack("<IiiIIIII", build.audit.MH_MAGIC_64, build.CPU_TYPE_ARM64,
                         0, build.MH_DYLIB, 2, sizeofcmds, 0, 0)
    return header + id_cmd + build_cmd


class Arm64EncodingTests(unittest.TestCase):
    def test_bl_encodes_forward_call(self):
        word = build.encode_bl(0x1011107E4, 0x1026F0C20)
        self.assertEqual(word >> 26, 0b100101)
        immediate = word & 0x03FFFFFF
        if immediate & (1 << 25):
            immediate -= 1 << 26
        self.assertEqual(0x1011107E4 + immediate * 4, 0x1026F0C20)

    def test_bl_rejects_out_of_range_and_unaligned_targets(self):
        with self.assertRaises(ValueError):
            build.encode_bl(0x1000, 0x90000000)
        with self.assertRaises(ValueError):
            build.encode_bl(0x1000, 0x1002)

    def test_adrp_and_add_reconstruct_data_address(self):
        pc = 0x1026F0C30
        target = build.DATA_VA
        adrp = build.encode_adrp(22, pc, target)
        imm21 = (((adrp >> 5) & 0x7FFFF) << 2) | ((adrp >> 29) & 3)
        if imm21 & (1 << 20):
            imm21 -= 1 << 21
        page = (pc & ~0xFFF) + (imm21 << 12)
        add = build.encode_add_lo12(22, 22, target)
        low = (add >> 10) & 0xFFF
        self.assertEqual(page + low, target)


class PublicComponentTests(unittest.TestCase):
    def test_ci_helper_must_match_reproducible_local_build(self):
        expected = b"pinned helper bytes"
        self.assertEqual(build.select_helper(expected, expected), expected)
        self.assertEqual(build.select_helper(None, expected), expected)
        with self.assertRaisesRegex(ValueError, "differs from deterministic helper"):
            build.select_helper(b"changed helper", expected)

    def test_ios_dylib_validation_checks_platform_and_install_name(self):
        build.validate_dylib(ios_test_dylib())
        with self.assertRaisesRegex(ValueError, "iOS platform"):
            build.validate_dylib(ios_test_dylib(platform=7))
        with self.assertRaisesRegex(ValueError, "install name"):
            build.validate_dylib(ios_test_dylib(install_name="@rpath/GooseJump.dylib"))

    def test_linked_helper_fits_padding_and_addresses_state_page(self):
        with tempfile.TemporaryDirectory() as tmp:
            helper = build.make_helper(Path(tmp), "clang", "ld.lld", "llvm-objcopy", "llvm-nm")
        self.assertGreater(len(helper), 0)
        self.assertLessEqual(len(helper), build.CODE_END_VA - build.HELPER_VA)
        adrp = struct.unpack_from("<I", helper, 16)[0]
        imm21 = (((adrp >> 5) & 0x7FFFF) << 2) | ((adrp >> 29) & 3)
        if imm21 & (1 << 20):
            imm21 -= 1 << 21
        page = (build.HELPER_VA + 16 & ~0xFFF) + (imm21 << 12)
        add = struct.unpack_from("<I", helper, 20)[0]
        self.assertEqual(page + ((add >> 10) & 0xFFF), build.DATA_VA)


@unittest.skipUnless((ROOT / "extracted/Payload/untitledgooseport.app/untitledgooseport").is_file(),
                     "private source executable is absent from source-only CI")
class PatcherTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = (ROOT / "extracted/Payload/untitledgooseport.app/untitledgooseport").read_bytes()

    def test_rejects_wrong_source_hash(self):
        with self.assertRaisesRegex(ValueError, "hash mismatch"):
            build.patch_executable(self.original[:-1] + bytes([self.original[-1] ^ 1]), b"\x1f\x20\x03\xd5")

    def test_honk_rigidbody_call_targets_are_verified_function_entries(self):
        image = build.audit.macho_info(build.audit.EXE)
        starts = set(image["function_starts"])
        required = {
            build.BASE + 0x1E15850,  # Rigidbody.get_velocity
            build.BASE + 0x1E158FC,  # Rigidbody.set_velocity
            build.BASE + 0x1E16108,  # Rigidbody.get_position
            build.BASE + 0x1E16454,  # Rigidbody.MovePosition
            build.BASE + 0x1DE9FE0,  # Time.get_timeScale
        }
        self.assertTrue(required.issubset(starts))
        with tempfile.TemporaryDirectory() as temp:
            helper = build.make_helper(Path(temp), "clang", "ld.lld", "llvm-objcopy", "llvm-nm")
        self.assertLessEqual(len(helper), build.CODE_END_VA - build.HELPER_VA)

    def test_package_never_targets_original_or_extracted_inputs(self):
        for protected in (build.IPA, ROOT / "extracted/Payload/untitledgooseport.app/untitledgooseport"):
            with self.subTest(protected=protected), self.assertRaisesRegex(ValueError, "preserved"):
                build.package(protected, b"", b"", b"", force=True)
        with self.assertRaisesRegex(ValueError, "inside the goose-jump workspace"):
            build.package(Path("/tmp/goose-jump-forbidden.ipa"), b"", b"", b"", force=True)

    def test_patched_copy_declares_sections_and_load_command(self):
        helper = bytes.fromhex("ff8300d1f60b00f9fe0f00f9740a40f9")
        patched = build.patch_executable(self.original, helper)
        build.validate_patched(patched, helper)
        self.assertEqual(struct.unpack_from("<I", patched, build.HOOK_FILEOFF)[0],
                         build.encode_bl(build.HOOK_VA, build.HELPER_VA))
        self.assertEqual(self.original[build.HOOK_FILEOFF:build.HOOK_FILEOFF + 4],
                         struct.pack("<I", build.HOOK_ORIGINAL))

    def test_rejects_duplicate_patch(self):
        helper = bytes.fromhex("ff8300d1f60b00f9fe0f00f9740a40f9")
        patched = build.patch_executable(self.original, helper)
        with self.assertRaisesRegex(ValueError, "hash mismatch"):
            build.patch_executable(patched, helper)

    def test_patched_output_is_reproducible_and_keeps_uuid(self):
        helper = bytes.fromhex("ff8300d1f60b00f9fe0f00f9740a40f9")
        first = build.patch_executable(self.original, helper)
        second = build.patch_executable(self.original, helper)
        self.assertEqual(first, second)
        self.assertEqual(build.macho_uuid(first), build.EXPECTED_UUID)

    def test_ipa_validation_checks_structure_arch_dependency_and_assets(self):
        helper = bytes.fromhex("ff8300d1f60b00f9fe0f00f9740a40f9")
        patched = build.patch_executable(self.original, helper)
        dylib = ios_test_dylib()
        tmp = Path(tempfile.mkdtemp(prefix="goose-ipa-validation-"))
        original_ipa = tmp / "original.ipa"
        output_ipa = tmp / "output.ipa"
        bad_ipa = tmp / "bad.ipa"
        old_ipa = build.IPA
        info = plistlib.dumps({"CFBundleExecutable": build.EXE_NAME,
                               "CFBundleIdentifier": "com.dalmac.untitledgooseport"})
        metadata = (ROOT / "extracted/Payload/untitledgooseport.app/Data/Managed/Metadata/global-metadata.dat").read_bytes()
        stable_asset = b"unchanged unity asset"
        names = [f"Payload/{build.APP_NAME}/Info.plist", build.IPA_EXE,
                 build.IPA_METADATA, f"Payload/{build.APP_NAME}/Data/asset.bin",
                 f"Payload/{build.APP_NAME}/_CodeSignature/CodeResources"]
        try:
            with zipfile.ZipFile(original_ipa, "w") as archive:
                for name, data in ((names[0], info), (names[1], self.original),
                                   (names[2], metadata), (names[3], stable_asset),
                                   (names[4], b"old signature")):
                    archive.writestr(name, data)
            with zipfile.ZipFile(output_ipa, "w") as archive:
                for name, data in ((names[0], info), (names[1], patched),
                                   (names[2], metadata), (names[3], stable_asset),
                                   (build.DYLIB_PATH, dylib)):
                    archive.writestr(name, data)
            build.IPA = original_ipa
            build.validate_ipa(output_ipa, helper, dylib)
            with zipfile.ZipFile(output_ipa, "r") as source, zipfile.ZipFile(bad_ipa, "w") as bad:
                for item in source.infolist():
                    data = source.read(item.filename)
                    if item.filename == names[3]: data = b"changed asset"
                    bad.writestr(item, data)
            with self.assertRaisesRegex(ValueError, "resource changed unexpectedly"):
                build.validate_ipa(bad_ipa, helper, dylib)
        finally:
            build.IPA = old_ipa
            import shutil
            shutil.rmtree(tmp)


if __name__ == "__main__":
    unittest.main()
