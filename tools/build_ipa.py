#!/usr/bin/env python3
"""Build a version-pinned unsigned Goose Jump IPA from the untouched source IPA."""
from __future__ import annotations

import argparse
import hashlib
import plistlib
import re
import shutil
import struct
import subprocess
import tempfile
import zipfile
from pathlib import Path

import audit

ROOT = Path(__file__).resolve().parents[1]
IPA = ROOT / "original/Untitled Goose Game[tg@dalmac_ports].ipa"
APP_NAME = "untitledgooseport.app"
EXE_NAME = "untitledgooseport"
IPA_EXE = f"Payload/{APP_NAME}/{EXE_NAME}"
DYLIB_PATH = f"Payload/{APP_NAME}/Frameworks/GooseJump.dylib"
DYLIB_INSTALL_NAME = "@executable_path/Frameworks/GooseJump.dylib"
EXPECTED_IPA_SHA256 = "70b1cc33d2f6f753113f9801a0ffffa27245796676052121968d26c355f78593"
EXPECTED_EXE_SHA256 = "0d09efea89208a960adc68a86ab534653c29f9976466dc532d6d703334d7c0c9"
EXPECTED_METADATA_SHA256 = "6cd38d42a7e7a13e9de6780f02857c8545cd1b4dea881f353eba2e0e90f38210"
EXPECTED_UUID = bytes.fromhex("8c9e468f0d5439e5864f176491607698")
IPA_METADATA = f"Payload/{APP_NAME}/Data/Managed/Metadata/global-metadata.dat"
BASE = 0x100000000
HOOK_VA = 0x1011107E4
HOOK_FILEOFF = 0x11107E4
HOOK_ORIGINAL = 0xF9400A74  # ldr x20, [x19, #16]
HELPER_VA = 0x1026F0C20
HELPER_FILEOFF = 0x26F0C20
CODE_END_VA = 0x1026F4000
DATA_VA = 0x102E1B000
DATA_SIZE = 0x1000
LC_LOAD_DYLIB = 0xC
LC_SEGMENT_64 = 0x19
LC_VERSION_MIN_IPHONEOS = 0x25
LC_BUILD_VERSION = 0x32
LC_ID_DYLIB = 0xD
PLATFORM_IOS = 2
MH_DYLIB = 6
CPU_TYPE_ARM64 = 0x0100000C
S_ZEROFILL = 1
S_ATTR_PURE_INSTRUCTIONS = 0x80000000
S_ATTR_SOME_INSTRUCTIONS = 0x00000400

RELOCS = {
    "goose_reloc_data_adrp": ("adrp", DATA_VA, 22),
    "goose_reloc_data_add": ("add", DATA_VA, 22),
    "goose_reloc_time_scale": ("bl", BASE + 0x1DE9FE0, None),
    "goose_reloc_command_time_scale": ("bl", BASE + 0x1DE9FE0, None),
    "goose_reloc_speed_get_velocity": ("bl", BASE + 0x1E15850, None),
    "goose_reloc_speed_set_velocity": ("bl", BASE + 0x1E158FC, None),
    "goose_reloc_get_position": ("bl", BASE + 0x1E16108, None),
    "goose_reloc_move_position": ("bl", BASE + 0x1E16454, None),
    "goose_reloc_teleport_clear_velocity": ("bl", BASE + 0x1E158FC, None),
    "goose_reloc_rb_kinematic": ("bl", BASE + 0x1E15DA8, None),
    "goose_reloc_rb_get_velocity": ("bl", BASE + 0x1E15850, None),
    "goose_reloc_rb_get_velocity_maintain": ("bl", BASE + 0x1E15850, None),
    "goose_reloc_rb_set_velocity": ("bl", BASE + 0x1E158FC, None),
    "goose_reloc_hover_kinematic": ("bl", BASE + 0x1E15DA8, None),
    "goose_reloc_hover_get_velocity": ("bl", BASE + 0x1E15850, None),
    "goose_reloc_hover_set_velocity": ("bl", BASE + 0x1E158FC, None),
    "goose_reloc_component_transform": ("bl", BASE + 0x1DBA100, None),
    "goose_reloc_scale_component_transform": ("bl", BASE + 0x1DBA100, None),
    "goose_reloc_transform_get_scale": ("bl", BASE + 0x1DEB834, None),
    "goose_reloc_transform_set_scale": ("bl", BASE + 0x1DEB8E0, None),
    "goose_reloc_rate_get_time_scale": ("bl", BASE + 0x1DE9FE0, None),
    "goose_reloc_set_time_scale": ("bl", BASE + 0x1DEA040, None),
    "goose_reloc_restore_get_time_scale": ("bl", BASE + 0x1DE9FE0, None),
    "goose_reloc_restore_time_scale": ("bl", BASE + 0x1DEA040, None),
}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def encode_bl(pc: int, target: int) -> int:
    delta = target - pc
    if delta & 3 or not -(1 << 27) <= delta < (1 << 27):
        raise ValueError(f"BL target out of range or unaligned: {pc:#x} -> {target:#x}")
    return 0x94000000 | ((delta >> 2) & 0x03FFFFFF)


def encode_adrp(rd: int, pc: int, target: int) -> int:
    delta = (target >> 12) - (pc >> 12)
    if not -(1 << 20) <= delta < (1 << 20):
        raise ValueError(f"ADRP target out of range: {pc:#x} -> {target:#x}")
    imm = delta & 0x1FFFFF
    return 0x90000000 | ((imm & 3) << 29) | (((imm >> 2) & 0x7FFFF) << 5) | rd


def encode_add_lo12(rd: int, rn: int, target: int) -> int:
    return 0x91000000 | ((target & 0xFFF) << 10) | (rn << 5) | rd


def parse_commands(data: bytes):
    if len(data) < 32 or struct.unpack_from("<I", data)[0] != audit.MH_MAGIC_64:
        raise ValueError("expected little-endian 64-bit Mach-O")
    fields = list(audit.MACHO.unpack_from(data))
    _, _, _, _, ncmds, sizeofcmds, _, _ = fields
    commands = []
    pos = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, pos)
        if size < 8 or pos + size > 32 + sizeofcmds:
            raise ValueError("invalid load command bounds")
        commands.append((cmd, bytearray(data[pos:pos + size])))
        pos += size
    if pos != 32 + sizeofcmds:
        raise ValueError("load command size mismatch")
    return fields, commands


def macho_uuid(data: bytes) -> bytes:
    _, commands = parse_commands(data)
    for cmd, raw in commands:
        if cmd == 0x1B and len(raw) >= 24:
            return bytes(raw[8:24])
    raise ValueError("Mach-O is missing LC_UUID")


def section_record(name: str, segment: str, addr: int, size: int,
                   offset: int, align: int, flags: int) -> bytes:
    def fixed(s: str) -> bytes:
        raw = s.encode("ascii")
        if len(raw) > 16:
            raise ValueError("Mach-O section name exceeds 16 bytes")
        return raw.ljust(16, b"\0")
    return struct.pack("<16s16sQQIIIIIIII", fixed(name), fixed(segment), addr,
                       size, offset, align, 0, 0, flags, 0, 0, 0)


def dylib_command(name: str) -> bytes:
    raw = name.encode("utf-8") + b"\0"
    size = (24 + len(raw) + 7) & ~7
    return struct.pack("<IIIIII", LC_LOAD_DYLIB, size, 24, 0, 0, 0) + raw.ljust(size - 24, b"\0")


def patch_load_commands(data: bytearray) -> None:
    fields, commands = parse_commands(data)
    if any(cmd == LC_LOAD_DYLIB and b"GooseJump.dylib" in raw for cmd, raw in commands):
        raise ValueError("binary already contains GooseJump load command")
    targets = {"__TEXT": ("__goose", HELPER_VA, CODE_END_VA - HELPER_VA,
                           HELPER_FILEOFF, 2,
                           S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS),
               "__DATA": ("__goose", DATA_VA, DATA_SIZE, 0, 3, S_ZEROFILL)}
    done = set()
    rebuilt = []
    for cmd, raw in commands:
        if cmd == LC_SEGMENT_64:
            seg = bytes(raw[8:24]).split(b"\0", 1)[0].decode("ascii")
            if seg in targets:
                if seg in done:
                    raise ValueError(f"duplicate {seg} segment command")
                name, addr, size, offset, align, flags = targets[seg]
                vmaddr, vmsize = struct.unpack_from("<QQ", raw, 24)
                nsects = struct.unpack_from("<I", raw, 64)[0]
                old_size = struct.unpack_from("<I", raw, 4)[0]
                if old_size != 72 + 80 * nsects:
                    raise ValueError(f"unexpected {seg} section command layout")
                if not (vmaddr <= addr and addr + size <= vmaddr + vmsize):
                    raise ValueError(f"new section outside {seg} segment mapping")
                raw.extend(section_record(name, seg, addr, size, offset, align, flags))
                struct.pack_into("<I", raw, 4, old_size + 80)
                struct.pack_into("<I", raw, 64, nsects + 1)
                done.add(seg)
        rebuilt.append(bytes(raw))
    if done != set(targets):
        raise ValueError(f"missing target segments: {set(targets) - done}")
    rebuilt.append(dylib_command(DYLIB_INSTALL_NAME))
    blob = b"".join(rebuilt)
    new_end = 32 + len(blob)
    first_section = 0x4000  # pinned original __TEXT file mapping begins at 0x4000
    if new_end > first_section:
        raise ValueError("not enough Mach-O header padding for added sections/load command")
    struct.pack_into("<I", data, 16, len(rebuilt))
    struct.pack_into("<I", data, 20, len(blob))
    data[32:new_end] = blob
    data[new_end:first_section] = b"\0" * (first_section - new_end)


def patch_helper(blob: bytes, nm_output: str) -> bytes:
    names = {}
    for line in nm_output.splitlines():
        m = re.match(r"^([0-9a-fA-F]+)\s+\w\s+(\S+)$", line.strip())
        if m:
            names[m.group(2)] = int(m.group(1), 16)
    if names.get("goose_jump_helper") != HELPER_VA:
        raise ValueError("helper link address differs from pinned code cave")
    out = bytearray(blob)
    for symbol, (kind, target, reg) in RELOCS.items():
        if symbol not in names:
            raise ValueError(f"missing helper relocation marker: {symbol}")
        at = names[symbol] - HELPER_VA
        if at < 0 or at + 4 > len(out) or at & 3:
            raise ValueError(f"invalid helper relocation location: {symbol}")
        expected = {"bl": 0x94000000, "adrp": 0x90000016, "add": 0x910002D6}[kind]
        if struct.unpack_from("<I", out, at)[0] != expected:
            raise ValueError(f"helper relocation placeholder mismatch: {symbol}")
        if kind == "bl":
            word = encode_bl(names[symbol], target)
        elif kind == "adrp":
            word = encode_adrp(reg, names[symbol], target)
        else:
            word = encode_add_lo12(reg, reg, target)
        struct.pack_into("<I", out, at, word)
    return bytes(out)


def make_helper(temp: Path, clang: str, ld: str, objcopy: str, nm: str) -> bytes:
    obj = temp / "jump_helper.o"
    elf = temp / "jump_helper.elf"
    raw = temp / "jump_helper.bin"
    subprocess.run([clang, "--target=aarch64-linux-gnu", "-c",
                    str(ROOT / "src/jump_helper.S"), "-o", str(obj)], check=True)
    subprocess.run([ld, "-m", "aarch64elf", f"-Ttext={HELPER_VA:#x}", "--no-pie",
                    "--build-id=none", "--entry=goose_jump_helper", "-o", str(elf), str(obj)], check=True)
    subprocess.run([objcopy, "-O", "binary", "--only-section=.text", str(elf), str(raw)], check=True)
    nm_output = subprocess.check_output([nm, "-n", str(elf)], text=True)
    return patch_helper(raw.read_bytes(), nm_output)


def select_helper(candidate: bytes | None, rebuilt: bytes) -> bytes:
    """Accept a CI helper only when it exactly matches this source/toolchain build."""
    if candidate is not None and candidate != rebuilt:
        raise ValueError("CI helper differs from deterministic helper built from checked-in source")
    return rebuilt if candidate is None else candidate


def verify_source_archive() -> tuple[bytes, bytes]:
    if sha256(IPA.read_bytes()) != EXPECTED_IPA_SHA256:
        raise ValueError("original IPA hash mismatch; refusing unsupported binary")
    with zipfile.ZipFile(IPA) as zf:
        try:
            exe = zf.read(IPA_EXE)
            metadata = zf.read(IPA_METADATA)
        except KeyError as exc:
            raise ValueError("source IPA lacks a pinned executable or IL2CPP metadata file") from exc
    if sha256(exe) != EXPECTED_EXE_SHA256:
        raise ValueError("original executable hash mismatch; refusing unsupported binary")
    if macho_uuid(exe) != EXPECTED_UUID:
        raise ValueError("original executable UUID mismatch; refusing unsupported binary")
    if sha256(metadata) != EXPECTED_METADATA_SHA256:
        raise ValueError("metadata hash mismatch; refusing unsupported binary")
    magic = bytes(byte ^ 0x5A for byte in metadata[:4])
    if magic != bytes.fromhex("af1bb1fa") or struct.unpack_from("<I", metadata, 4)[0] != 24:
        raise ValueError("metadata header/version mismatch; refusing unsupported binary")
    return IPA.read_bytes(), exe


def patch_executable(original: bytes, helper: bytes) -> bytes:
    if sha256(original) != EXPECTED_EXE_SHA256:
        raise ValueError("executable hash mismatch; refusing unsupported binary")
    fields, commands = parse_commands(original)
    if fields[1] != CPU_TYPE_ARM64 or fields[3] != 2:
        raise ValueError("expected ARM64 Mach-O executable")
    segments = {}
    for cmd, raw in commands:
        if cmd == LC_SEGMENT_64:
            seg = bytes(raw[8:24]).split(b"\0", 1)[0].decode("ascii")
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", raw, 24)
            sections = []
            count = struct.unpack_from("<I", raw, 64)[0]
            for index in range(count):
                off = 72 + 80 * index
                addr, size = struct.unpack_from("<QQ", raw, off + 32)
                sections.append((addr, size))
            segments[seg] = (vmaddr, vmsize, fileoff, filesize, sections)
    if "__TEXT" not in segments or "__DATA" not in segments:
        raise ValueError("missing required Mach-O segments")
    text, data_seg = segments["__TEXT"], segments["__DATA"]
    if (text[0] != BASE or HELPER_VA + len(helper) > CODE_END_VA or
            HELPER_FILEOFF < text[2] or HELPER_FILEOFF + len(helper) > text[2] + text[3]):
        raise ValueError("code cave is outside mapped/file-backed __TEXT")
    if not (data_seg[0] <= DATA_VA and DATA_VA + DATA_SIZE <= data_seg[0] + data_seg[1]):
        raise ValueError("jump state is outside __DATA mapping")
    for seg_name, seg, start, end in (("__TEXT", text, HELPER_VA, CODE_END_VA),
                                      ("__DATA", data_seg, DATA_VA, DATA_VA + DATA_SIZE)):
        for addr, size in seg[4]:
            if addr < end and start < addr + size:
                raise ValueError(f"proposed {seg_name} section overlaps existing section {addr:#x}..{addr + size:#x}")
    extracted_exe = ROOT / "extracted/Payload" / APP_NAME / EXE_NAME
    if not extracted_exe.is_file() or sha256(extracted_exe.read_bytes()) != EXPECTED_EXE_SHA256:
        raise ValueError("extracted executable missing or differs from pinned source")
    info = audit.macho_info(extracted_exe)
    starts = info["function_starts"]
    prev = max((x for x in starts if x <= HOOK_VA), default=None)
    nxt = min((x for x in starts if x > HOOK_VA), default=None)
    if HOOK_VA in starts or (prev, nxt) != (0x101110618, 0x101110B50):
        raise ValueError("Mover.FixedUpdate function interval differs from audited binary")
    if len(helper) == 0 or HELPER_VA + len(helper) > CODE_END_VA:
        raise ValueError("helper does not fit in verified padding")
    if len(helper) < 16 or struct.unpack_from("<I", helper, 12)[0] != HOOK_ORIGINAL:
        raise ValueError("helper does not replay the displaced instruction")
    if original[HELPER_FILEOFF:0x26F4000] != b"\0" * (0x26F4000 - HELPER_FILEOFF):
        raise ValueError("code cave is not all zero; refusing to overwrite")
    if struct.unpack_from("<I", original, HOOK_FILEOFF)[0] != HOOK_ORIGINAL:
        raise ValueError("hook instruction mismatch; refusing unsupported binary")
    out = bytearray(original)
    out[HELPER_FILEOFF:HELPER_FILEOFF + len(helper)] = helper
    struct.pack_into("<I", out, HOOK_FILEOFF, encode_bl(HOOK_VA, HELPER_VA))
    patch_load_commands(out)
    return bytes(out)


def validate_dylib(blob: bytes) -> None:
    if len(blob) < 32 or struct.unpack_from("<I", blob)[0] != audit.MH_MAGIC_64:
        raise ValueError("JumpOverlay input is not a 64-bit Mach-O dylib")
    _, cpu, _, filetype, ncmds, sizeofcmds, _, _ = audit.MACHO.unpack_from(blob)
    if cpu != CPU_TYPE_ARM64 or filetype != MH_DYLIB:
        raise ValueError("JumpOverlay must be an ARM64 MH_DYLIB")
    if ncmds == 0 or 32 + sizeofcmds > len(blob):
        raise ValueError("invalid JumpOverlay load commands")
    _, commands = parse_commands(blob)
    is_ios = False
    has_expected_id = False
    for cmd, raw in commands:
        if cmd == LC_VERSION_MIN_IPHONEOS:
            is_ios = True
        elif cmd == LC_BUILD_VERSION and len(raw) >= 24:
            is_ios |= struct.unpack_from("<I", raw, 8)[0] == PLATFORM_IOS
        elif cmd == LC_ID_DYLIB:
            name_offset = struct.unpack_from("<I", raw, 8)[0]
            path = bytes(raw[name_offset:]).split(b"\0", 1)[0]
            has_expected_id = path == DYLIB_INSTALL_NAME.encode("utf-8")
    if not is_ios:
        raise ValueError("JumpOverlay lacks an iOS platform load command")
    if not has_expected_id:
        raise ValueError("JumpOverlay install name does not match the guest bundle path")


def signature_member(name: str) -> bool:
    return ("/_CodeSignature/" in name or name.endswith("/_CodeSignature") or
            name.endswith("/embedded.mobileprovision"))


def member_sha256(archive: zipfile.ZipFile, name: str) -> str:
    digest = hashlib.sha256()
    with archive.open(name) as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_ipa(path: Path, helper: bytes, dylib: bytes) -> None:
    with zipfile.ZipFile(IPA, "r") as original, zipfile.ZipFile(path, "r") as built:
        if built.testzip() is not None:
            raise ValueError("output IPA has a corrupt ZIP member")
        names = built.namelist()
        if len(names) != len(set(names)):
            raise ValueError("output IPA contains duplicate ZIP paths")
        expected_entries = {name for name in original.namelist()
                            if name != IPA_EXE and not signature_member(name)}
        expected_entries.add(DYLIB_PATH)
        expected_entries.add(IPA_EXE)
        if set(names) != expected_entries:
            missing = expected_entries - set(names)
            extra = set(names) - expected_entries
            raise ValueError(f"IPA bundle contents differ: missing={sorted(missing)[:5]}, extra={sorted(extra)[:5]}")
        for required in (f"Payload/{APP_NAME}/Info.plist", IPA_EXE,
                         IPA_METADATA, DYLIB_PATH):
            if required not in names:
                raise ValueError(f"IPA is missing required bundle member: {required}")
        plist = plistlib.loads(built.read(f"Payload/{APP_NAME}/Info.plist"))
        if plist.get("CFBundleExecutable") != EXE_NAME:
            raise ValueError("bundle Info.plist does not identify the expected executable")
        exe = built.read(IPA_EXE)
        validate_patched(exe, helper)
        included_dylib = built.read(DYLIB_PATH)
        if included_dylib != dylib:
            raise ValueError("packaged JumpOverlay dylib differs from compiled input")
        validate_dylib(included_dylib)
        for name in expected_entries:
            if name in (IPA_EXE, DYLIB_PATH) or name not in original.namelist():
                continue
            if member_sha256(original, name) != member_sha256(built, name):
                raise ValueError(f"original app resource changed unexpectedly: {name}")


def validate_patched(exe: bytes, helper: bytes) -> None:
    fields, commands = parse_commands(exe)
    if fields[1] != CPU_TYPE_ARM64 or fields[3] != 2:
        raise ValueError("patched executable header changed unexpectedly")
    if struct.unpack_from("<I", exe, HOOK_FILEOFF)[0] != encode_bl(HOOK_VA, HELPER_VA):
        raise ValueError("patched call site does not branch to helper")
    if exe[HELPER_FILEOFF:HELPER_FILEOFF + len(helper)] != helper:
        raise ValueError("embedded helper differs from built helper")
    if macho_uuid(exe) != EXPECTED_UUID:
        raise ValueError("patched executable UUID changed")
    seen = set()
    has_dylib = False
    for cmd, raw in commands:
        if cmd == LC_SEGMENT_64:
            seg = bytes(raw[8:24]).split(b"\0", 1)[0].decode("ascii")
            count = struct.unpack_from("<I", raw, 64)[0]
            for index in range(count):
                off = 72 + 80 * index
                section = bytes(raw[off:off + 16]).split(b"\0", 1)[0].decode("ascii")
                segment = bytes(raw[off + 16:off + 32]).split(b"\0", 1)[0].decode("ascii")
                addr, size = struct.unpack_from("<QQ", raw, off + 32)
                if section == "__goose" and segment == seg:
                    seen.add(seg)
                    if seg == "__TEXT" and (addr != HELPER_VA or size != CODE_END_VA - HELPER_VA):
                        raise ValueError("unexpected executable helper section range")
                    if seg == "__DATA" and (addr != DATA_VA or size != DATA_SIZE):
                        raise ValueError("unexpected jump-state section range")
        elif cmd == LC_LOAD_DYLIB:
            name_offset = struct.unpack_from("<I", raw, 8)[0]
            path = bytes(raw[name_offset:]).split(b"\0", 1)[0]
            if path == DYLIB_INSTALL_NAME.encode("utf-8"):
                has_dylib = True
    if seen != {"__TEXT", "__DATA"} or not has_dylib:
        raise ValueError("new sections or dylib load command missing")


def package(out_path: Path, patched: bytes, dylib: bytes, helper: bytes, force: bool) -> None:
    out_path = out_path.resolve()
    if ROOT.resolve() not in out_path.parents:
        raise ValueError("output must stay inside the goose-jump workspace")
    protected_dirs = ((ROOT / "original").resolve(), (ROOT / "extracted").resolve())
    if any(out_path == protected or protected in out_path.parents for protected in protected_dirs):
        raise ValueError("output path points into preserved original/extracted inputs")
    if out_path.exists() and not force:
        raise FileExistsError(f"output exists (use --force to replace): {out_path}")
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="goose-jump-ipa-") as tmp:
        extracted = Path(tmp) / "Payload"
        with zipfile.ZipFile(IPA) as src:
            src.extractall(tmp)
        app = extracted / APP_NAME
        exe_path = app / EXE_NAME
        if sha256(exe_path.read_bytes()) != EXPECTED_EXE_SHA256:
            raise ValueError("extracted executable hash mismatch")
        exe_path.write_bytes(patched)
        fw = app / "Frameworks"
        fw.mkdir(exist_ok=True)
        dylib_path = fw / "GooseJump.dylib"
        dylib_path.write_bytes(dylib)
        dylib_path.chmod(0o755)
        # The source signature cannot remain valid after code and load-command edits.
        shutil.rmtree(app / "_CodeSignature", ignore_errors=True)
        (app / "embedded.mobileprovision").unlink(missing_ok=True)
        tmpout = out_path.with_suffix(out_path.suffix + ".tmp")
        with zipfile.ZipFile(IPA, "r") as src, zipfile.ZipFile(tmpout, "w") as dst:
            for item in src.infolist():
                name = item.filename
                if name == IPA_EXE or signature_member(name):
                    continue
                if name == DYLIB_PATH:
                    continue
                p = Path(tmp) / name
                if p.is_file():
                    dst.writestr(item, p.read_bytes())
                elif item.is_dir():
                    dst.writestr(item, b"")
            exe_info = zipfile.ZipInfo(IPA_EXE, date_time=(2026, 1, 1, 0, 0, 0))
            exe_info.compress_type = zipfile.ZIP_DEFLATED
            exe_info.external_attr = (0o100755 << 16)
            dst.writestr(exe_info, patched)
            dylib_info = zipfile.ZipInfo(DYLIB_PATH, date_time=(2026, 1, 1, 0, 0, 0))
            dylib_info.compress_type = zipfile.ZIP_DEFLATED
            dylib_info.external_attr = (0o100755 << 16)
            dst.writestr(dylib_info, dylib)
        validate_ipa(tmpout, helper, dylib)
        if out_path.exists() and force:
            out_path.unlink()
        tmpout.replace(out_path)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dylib", type=Path, required=True, help="ARM64 iOS GooseJump.dylib built with an iOS SDK")
    parser.add_argument("--helper", type=Path,
                        help="optional CI-built helper; must exactly match local deterministic assembly/link")
    parser.add_argument("--out", type=Path, default=ROOT / "build/UntitledGooseGame-JumpMod-LiveContainer-unsigned.ipa")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--clang", default="clang")
    parser.add_argument("--ld", default="ld.lld")
    parser.add_argument("--objcopy", default="llvm-objcopy")
    parser.add_argument("--nm", default="llvm-nm")
    args = parser.parse_args()
    _, original = verify_source_archive()
    dylib = args.dylib.read_bytes()
    validate_dylib(dylib)
    with tempfile.TemporaryDirectory(prefix="goose-jump-helper-") as td:
        rebuilt_helper = make_helper(Path(td), args.clang, args.ld, args.objcopy, args.nm)
    helper = select_helper(args.helper.read_bytes() if args.helper else None, rebuilt_helper)
    patched = patch_executable(original, helper)
    validate_patched(patched, helper)
    package(args.out.resolve(), patched, dylib, helper, args.force)
    print(f"Unsigned IPA: {args.out.resolve()}")
    print(f"Patched executable SHA-256: {sha256(patched)}")
    print(f"Embedded helper: {len(helper)} bytes at file offset {HELPER_FILEOFF:#x}")
    print(f"Hook: {HOOK_VA:#x} -> {HELPER_VA:#x}; original instruction {HOOK_ORIGINAL:#010x}")
    print("LiveContainer import/runtime behavior remains unvalidated; JIT can bypass signature checks only when LiveContainer successfully enables it.")


if __name__ == "__main__":
    main()
