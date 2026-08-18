#!/usr/bin/env python3
"""Change Joe's Mach-O load command from required to weak."""

from __future__ import annotations

import os
import struct
import sys
from pathlib import Path


LC_LOAD_DYLIB = 0xC
LC_LOAD_WEAK_DYLIB = 0x80000018
MH_MAGIC = 0xFEEDFACE
MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM = 0xCEFAEDFE
MH_CIGAM_64 = 0xCFFAEDFE
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
FAT_CIGAM = 0xBEBAFECA
FAT_CIGAM_64 = 0xBFBAFECA


def slices(data: bytearray) -> list[tuple[int, int]]:
    if len(data) < 4:
        return []

    magic = struct.unpack_from(">I", data)[0]
    if magic not in {FAT_MAGIC, FAT_MAGIC_64, FAT_CIGAM, FAT_CIGAM_64}:
        return [(0, len(data))]

    endian = ">" if magic in {FAT_MAGIC, FAT_MAGIC_64} else "<"
    is_64 = magic in {FAT_MAGIC_64, FAT_CIGAM_64}
    count = struct.unpack_from(f"{endian}I", data, 4)[0]
    entry_size = 32 if is_64 else 20
    entries: list[tuple[int, int]] = []
    for index in range(count):
        entry = 8 + index * entry_size
        if entry + entry_size > len(data):
            raise ValueError("truncated universal Mach-O header")
        if is_64:
            offset, size = struct.unpack_from(f"{endian}QQ", data, entry + 8)
        else:
            offset, size = struct.unpack_from(f"{endian}II", data, entry + 8)
        entries.append((offset, size))
    return entries


def patch_slice(data: bytearray, base: int, size: int) -> tuple[int, int]:
    if base + 28 > len(data) or size < 28:
        return (0, 0)

    magic = struct.unpack_from("<I", data, base)[0]
    if magic in {MH_MAGIC, MH_MAGIC_64}:
        endian = "<"
        header_size = 32 if magic == MH_MAGIC_64 else 28
    elif magic in {MH_CIGAM, MH_CIGAM_64}:
        endian = ">"
        header_size = 32 if magic == MH_CIGAM_64 else 28
    else:
        return (0, 0)

    ncmds = struct.unpack_from(f"{endian}I", data, base + 16)[0]
    cursor = base + header_size
    limit = min(base + size, len(data))
    matched = 0
    changed = 0

    for _ in range(ncmds):
        if cursor + 8 > limit:
            raise ValueError("truncated Mach-O load commands")
        command, command_size = struct.unpack_from(f"{endian}II", data, cursor)
        if command_size < 8 or cursor + command_size > limit:
            raise ValueError("invalid Mach-O load command size")
        if command in {LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB} and command_size >= 24:
            name_offset = struct.unpack_from(f"{endian}I", data, cursor + 8)[0]
            name_start = cursor + name_offset
            name_end = data.find(b"\0", name_start, cursor + command_size)
            if name_end != -1:
                name = data[name_start:name_end].decode("utf-8", errors="replace")
                if name.endswith("/joe.framework/joe"):
                    matched += 1
                    if command == LC_LOAD_DYLIB:
                        struct.pack_into(f"{endian}I", data, cursor, LC_LOAD_WEAK_DYLIB)
                        changed += 1
        cursor += command_size

    return (matched, changed)


def patch_file(path: Path) -> tuple[int, int]:
    if not path.is_file():
        return (0, 0)
    data = bytearray(path.read_bytes())
    matched = 0
    changed = 0
    for offset, size in slices(data):
        slice_matches, slice_changes = patch_slice(data, offset, size)
        matched += slice_matches
        changed += slice_changes
    if changed:
        path.write_bytes(data)
    return (matched, changed)


def remove_command_dictionary() -> None:
    products_dir = os.environ.get("BUILT_PRODUCTS_DIR")
    resources_path = os.environ.get("UNLOCALIZED_RESOURCES_FOLDER_PATH")
    if not products_dir or not resources_path:
        return
    dictionary = Path(products_dir, resources_path, "joeCommandDictionary.plist")
    if dictionary.is_file():
        dictionary.unlink()
        print(f"Removed {dictionary}")


def main() -> int:
    matched = 0
    changed = 0
    for argument in sys.argv[1:]:
        path = Path(argument)
        file_matches, file_changes = patch_file(path)
        matched += file_matches
        changed += file_changes
        if file_matches:
            print(f"Joe weak-linked in {path} ({file_changes} changed)")

    if matched == 0:
        products_dir = os.environ.get("BUILT_PRODUCTS_DIR")
        frameworks_path = os.environ.get("FRAMEWORKS_FOLDER_PATH")
        if products_dir and frameworks_path:
            framework = Path(products_dir, frameworks_path, "joe.framework")
            if not framework.exists():
                remove_command_dictionary()
                print("Joe is not linked for this platform; nothing to weaken")
                return 0
        print("error: no Joe Mach-O load command found", file=sys.stderr)
        return 1
    remove_command_dictionary()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
