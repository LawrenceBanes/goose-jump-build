#!/usr/bin/env python3
"""Read-only audit for the Goose Jump source app and IL2CPP metadata."""
from __future__ import annotations

import argparse
import hashlib
import json
import struct
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
IPA = ROOT / "original/Untitled Goose Game[tg@dalmac_ports].ipa"
APP = ROOT / "extracted/Payload/untitledgooseport.app"
EXE = APP / "untitledgooseport"
META = APP / "Data/Managed/Metadata/global-metadata.dat"
MACHO = struct.Struct("<IiiIIIII")
LC_SEGMENT_64 = 0x19
LC_FUNCTION_STARTS = 0x26
MH_MAGIC_64 = 0xFEEDFACF


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def read_uleb(data: bytes, pos: int) -> tuple[int, int]:
    value = shift = 0
    while True:
        if pos >= len(data):
            raise ValueError("truncated ULEB128")
        byte = data[pos]
        pos += 1
        value |= (byte & 0x7F) << shift
        if byte < 0x80:
            return value, pos
        shift += 7
        if shift > 63:
            raise ValueError("oversized ULEB128")


def macho_info(path: Path) -> dict:
    data = path.read_bytes()
    if len(data) < 32 or struct.unpack_from("<I", data)[0] != MH_MAGIC_64:
        raise ValueError("expected little-endian 64-bit Mach-O")
    _, cpu, subtype, filetype, ncmds, sizeofcmds, flags, _ = MACHO.unpack_from(data)
    pos = 32
    segments = []
    functions = None
    commands = []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, pos)
        if cmdsize < 8 or pos + cmdsize > len(data):
            raise ValueError("invalid Mach-O load command")
        if cmd == LC_SEGMENT_64:
            segname = data[pos + 8:pos + 24].split(b"\0", 1)[0].decode()
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", data, pos + 24)
            nsects = struct.unpack_from("<I", data, pos + 64)[0]
            sections = []
            for si in range(nsects):
                soff = pos + 72 + si * 80
                sectname = data[soff:soff + 16].split(b"\0", 1)[0].decode()
                ssegname = data[soff + 16:soff + 32].split(b"\0", 1)[0].decode()
                addr, size = struct.unpack_from("<QQ", data, soff + 32)
                offset, align, reloff, nreloc, sectflags = struct.unpack_from("<IIIII", data, soff + 48)
                sections.append({"name": sectname, "segment": ssegname, "addr": addr,
                                 "size": size, "offset": offset, "flags": sectflags})
            segments.append({"name": segname, "vmaddr": vmaddr, "vmsize": vmsize,
                             "fileoff": fileoff, "filesize": filesize, "sections": sections})
        elif cmd == LC_FUNCTION_STARTS:
            dataoff, datasize = struct.unpack_from("<II", data, pos + 8)
            functions = data[dataoff:dataoff + datasize]
        commands.append((cmd, cmdsize))
        pos += cmdsize
    if pos != 32 + sizeofcmds:
        raise ValueError("Mach-O load command size mismatch")
    text = next(s for s in segments if s["name"] == "__TEXT")
    function_starts = []
    if functions:
        cur = text["vmaddr"]
        i = 0
        while i < len(functions):
            delta, i = read_uleb(functions, i)
            if delta == 0:
                break
            cur += delta
            function_starts.append(cur)
    return {"cpu_type": cpu, "cpu_subtype": subtype, "filetype": filetype,
            "flags": flags, "segments": segments,
            "function_start_count": len(function_starts),
            "function_starts": function_starts,
            "commands": commands, "size": len(data)}


def metadata_info(path: Path) -> dict:
    raw = path.read_bytes()
    data = bytearray(raw)
    transformed = bytes(b ^ 0x5A for b in data[:4])
    if transformed == bytes.fromhex("af1bb1fa"):
        data[:4] = transformed
        first_four = "xor-0x5a"
    elif data[:4] == bytes.fromhex("af1bb1fa"):
        first_four = "plain"
    else:
        raise ValueError("metadata magic not recognized")
    magic, version = struct.unpack_from("<II", data)
    if magic != 0xFAB11BAF or version != 24:
        raise ValueError(f"unexpected metadata header: {magic:#x}, v{version}")
    pairs = [struct.unpack_from("<II", data, 8 + i * 8) for i in range(33)]
    # For this v24.1 layout: methods are 52-byte records, type definitions
    # are 100-byte records, images are 40-byte records.
    names_off, names_size = pairs[2]
    fields_off, fields_size = pairs[11]
    params_off, params_size = pairs[10]
    methods_off, methods_size = pairs[5]
    types_off, types_size = pairs[19]
    images_off, images_size = pairs[21]
    tables = {"method definitions": (methods_off, methods_size),
              "type definitions": (types_off, types_size),
              "images": (images_off, images_size)}
    tables["field definitions"] = (fields_off, fields_size)
    tables["parameter definitions"] = (params_off, params_size)
    for name, (off, size) in tables.items():
        if off + size > len(data):
            raise ValueError(f"{name} table exceeds metadata file")
    if methods_size % 52 or types_size % 100 or images_size % 40 or fields_size % 12:
        raise ValueError("metadata table lengths disagree with v24.1 record sizes")
    names = data[names_off:names_off + names_size]

    def getstr(index: int) -> str:
        if index < 0 or index >= len(names):
            return f"<bad-string:{index}>"
        end = names.find(0, index)
        if end < 0:
            return "<unterminated-string>"
        return names[index:end].decode("utf-8", "replace")

    target_ids = {7887, 7893, 7894}
    target_types = []
    for idx in target_ids:
        if idx >= types_size // 100:
            continue
        off = types_off + idx * 100
        vals = struct.unpack_from("<19I8HII", data, off)
        target_types.append({"index": idx, "name": getstr(vals[0]),
                             "namespace": getstr(vals[1]),
                             "method_start": vals[12], "method_count": vals[19],
                             "field_start": vals[11], "field_count": vals[21]})

    classes = []
    for idx in range(types_size // 100):
        off = types_off + idx * 100
        vals = struct.unpack_from("<19I8HII", data, off)
        name, namespace = getstr(vals[0]), getstr(vals[1])
        if name == "Mover" or (name in {"MobileControlsManager", "VirtualButton", "VirtualJoystick"}):
            method_start, method_count = vals[12], vals[19]
            methods = []
            for midx in range(method_start, method_start + method_count):
                moff = methods_off + midx * 52
                if moff + 52 > methods_off + methods_size:
                    raise ValueError("type method range exceeds method table")
                m = struct.unpack_from("<11I4H", data, moff)
                parameter_start, parameter_count = m[3], m[14]
                params = []
                for pidx in range(parameter_start, parameter_start + parameter_count):
                    poff = params_off + pidx * 12
                    if poff + 12 > params_off + params_size:
                        raise ValueError("method parameter range exceeds parameter table")
                    pname, ptoken, ptype = struct.unpack_from("<III", data, poff)
                    params.append(getstr(pname))
                methods.append({"name": getstr(m[0]), "method_index": m[5],
                                "token": m[10], "parameter_count": parameter_count,
                                "parameters": params})
            field_start, field_count = vals[11], vals[21]
            fields = []
            for fidx in range(field_start, field_start + field_count):
                foff = fields_off + fidx * 12
                if foff + 12 > fields_off + fields_size:
                    raise ValueError("type field range exceeds field table")
                fname, field_type, token = struct.unpack_from("<IiI", data, foff)
                fields.append({"name": getstr(fname), "type_index": field_type, "token": token})
            classes.append({"index": idx, "namespace": namespace, "name": name,
                            "method_start": method_start, "method_count": method_count,
                            "fields": fields, "methods": methods})
    # Check every nonempty header pair is within file bounds, without assuming
    # all later 24.x table variants have the same record interpretation.
    for i, (off, size) in enumerate(pairs):
        if off > len(data) or size > len(data) or off + size > len(data):
            raise ValueError(f"header table {i} exceeds metadata file")
    return {"size": len(raw), "first_four_transform": first_four, "version": version,
            "header_pair_count_checked": len(pairs),
            "method_count": methods_size // 52, "type_count": types_size // 100,
            "image_count": images_size // 40, "target_types": target_types,
            "classes": classes}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    m = macho_info(EXE)
    md = metadata_info(META)
    target = 0x1011107E0
    starts = m["function_starts"]
    preceding = max((x for x in starts if x <= target), default=None)
    following = min((x for x in starts if x > target), default=None)
    inside = next((s for s in m["segments"] if s["vmaddr"] <= target < s["vmaddr"] + s["vmsize"]), None)
    ipa_path = f"Payload/{APP.name}/{EXE.name}"
    with zipfile.ZipFile(IPA) as zf:
        archived_hash = hashlib.sha256(zf.read(ipa_path)).hexdigest()
    candidate_addresses = {
        "Mover.FixedUpdate candidate": target,
        "MobileControlsManager.BuildUI": 0x101102FC8,
        "MobileControlsManager.BuildButton": 0x101108804,
        "VirtualButton.OnPointerDown": 0x10110B524,
    }
    function_checks = {}
    for name, address in candidate_addresses.items():
        starts_at = max((x for x in starts if x <= address), default=None)
        ends_at = min((x for x in starts if x > address), default=None)
        segment = next((s for s in m["segments"] if s["vmaddr"] <= address < s["vmaddr"] + s["vmsize"]), None)
        section = next((x for s in m["segments"] for x in s["sections"]
                        if x["addr"] <= address < x["addr"] + x["size"]), None)
        function_checks[name] = {"address": hex(address), "is_function_start": address in starts,
                                 "preceding_start": hex(starts_at) if starts_at is not None else None,
                                 "next_start": hex(ends_at) if ends_at is not None else None,
                                 "segment": segment["name"] if segment else None,
                                 "section": f"{section['segment']},{section['name']}" if section else None}
    ui_calls = [0x10110349C, 0x101103540, 0x1011035E4, 0x101103688, 0x101103A1C, 0x101103ABC]
    call_targets = []
    raw_exe = EXE.read_bytes()
    for address in ui_calls:
        word = struct.unpack_from("<I", raw_exe, address - 0x100000000)[0]
        immediate = word & 0x03FFFFFF
        if immediate & (1 << 25):
            immediate -= 1 << 26
        call_targets.append({"address": hex(address), "instruction": hex(word),
                             "is_bl": word >> 26 == 0b100101,
                             "target": hex(address + immediate * 4)})
    report = {"ipa_sha256": sha256(IPA), "executable_sha256": sha256(EXE),
              "archived_executable_sha256": archived_hash,
              "archived_executable_matches_extracted": archived_hash == sha256(EXE),
              "macho": {k: v for k, v in m.items() if k != "function_starts"},
              "metadata": md,
              "candidate_fixedupdate_address": hex(target),
              "candidate_segment": inside["name"] if inside else None,
              "candidate_function_start": target in starts,
              "candidate_preceding_function_start": hex(preceding) if preceding else None,
              "candidate_following_function_start": hex(following) if following else None,
              "candidate_file_offset": hex(target - 0x100000000),
              "candidate_addresses": function_checks,
              "buildui_call_targets": call_targets,
              "sections": [section for seg in m["segments"] for section in seg["sections"]]}
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"IPA SHA-256: {report['ipa_sha256']}")
        print(f"Executable SHA-256: {report['executable_sha256']}")
        print(f"IPA executable matches extracted: {report['archived_executable_matches_extracted']}")
        print(f"Mach-O: ARM64, {m['size']:,} bytes; function starts: {m['function_start_count']:,}")
        print(f"Candidate {hex(target)}: segment={inside['name'] if inside else None}, "
              f"fileoff={report['candidate_file_offset']}, starts_function={target in starts}")
        print(f"Function interval: {report['candidate_preceding_function_start']}..{report['candidate_following_function_start']}")
        for name, check in function_checks.items():
            print(f"{name}: {check['address']} {check['section']} function_start={check['is_function_start']} "
                  f"interval={check['preceding_start']}..{check['next_start']}")
        print("BuildUI BuildButton call targets: " + ", ".join(c["target"] for c in call_targets))
        candidate_data = 0x102E1B000
        data_segment = next(s for s in m["segments"] if s["name"] == "__DATA")
        data_section = next((x for x in data_segment["sections"]
                             if x["addr"] <= candidate_data < x["addr"] + x["size"]), None)
        data_file_backed_end = data_segment["vmaddr"] + data_segment["filesize"]
        print(f"Data candidate 0x102e1b000: in __DATA={data_segment['vmaddr'] <= candidate_data < data_segment['vmaddr'] + data_segment['vmsize']}, "
              f"section={data_section['name'] if data_section else 'unsectioned'}, "
              f"file-backed={candidate_data < data_file_backed_end}")
        print(f"Metadata: v{md['version']}, first four={md['first_four_transform']}, "
              f"{md['type_count']:,} types, {md['method_count']:,} methods, {md['image_count']} images")
        for cls in md["classes"]:
            print(f"{cls['namespace']}.{cls['name']} [type {cls['index']}]: methods {cls['method_start']}+{cls['method_count']}")
            if cls["fields"]:
                print("  fields: " + ", ".join(f["name"] for f in cls["fields"]))
            for method in cls["methods"]:
                print(f"  {method['name']}({', '.join(method['parameters'])}) "
                      f"(methodIndex={method['method_index']}, token={method['token']:#x})")


if __name__ == "__main__":
    main()
