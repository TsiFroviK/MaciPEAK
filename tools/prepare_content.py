#!/usr/bin/env python3
"""Prepare the serialized files from PEAK's Windows Steam build for macOS."""

import argparse
import hashlib
import os
import re
import struct
import tempfile
from collections import Counter
from pathlib import Path

VERSION = b"6000.3.15f1"
# Unity 6000.3.15f1's UniversalRenderPipelineAsset MonoScript ID and runtime type hash.
URP_ASSET_TYPE = bytes.fromhex("4569bf26eccbf4e40c98378e038ba4d0ea78afb1b30663b7c04c956e9f2acdec")
PLAYER_SETTINGS_TYPE = bytes.fromhex("936fd1913a4f0b5da2ce7cadb0ce9666")


def exact(stream, size):
    data = stream.read(size)
    if len(data) != size:
        raise ValueError("truncated Unity file")
    return data


def cstring(stream):
    result = bytearray()
    while len(result) < 4096:
        byte = exact(stream, 1)
        if byte == b"\0":
            return bytes(result)
        result += byte
    raise ValueError("unterminated Unity string")


def atomic_write(dest, write):
    dest.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=dest.parent, prefix=".peak-", delete=False) as out:
        temp = Path(out.name)
        try:
            write(out)
            out.close()
            # NamedTemporaryFile starts at 0600. These completed player resources
            # must also be readable when another local account opens the .app.
            temp.chmod(0o644)
            os.replace(temp, dest)
        finally:
            if temp.exists():
                temp.unlink()


def shader_types(metadata, position):
    """Read Unity v22's type and object tables without materializing scene objects."""
    trees = metadata[position]
    number = struct.unpack_from("<I", metadata, position + 1)[0]
    pos = position + 5
    types = []
    for _ in range(number):
        start = pos
        class_id = struct.unpack_from("<i", metadata, pos)[0]
        pos += 23 + (16 if class_id == 114 else 0)
        if trees:
            nodes, strings = struct.unpack_from("<II", metadata, pos)
            pos += 8 + 32 * nodes + strings
            deps = struct.unpack_from("<I", metadata, pos)[0]
            pos += 4 + 4 * deps
        schema = metadata[start:pos] if class_id in (48, 72) else None
        if class_id == 114:
            schema = metadata[start + 7:start + 39]
        elif class_id == 129:
            schema = metadata[start + 7:start + 23]
        types.append((class_id, schema))
    objects = struct.unpack_from("<I", metadata, pos)[0]
    pos = (pos + 7) & ~3
    if pos + 24 * objects > len(metadata):
        raise ValueError("invalid Unity object table")
    return trees, types, objects, pos


def urp_drawer_mode(raw):
    """Locate the byte enum in the verified Core RP 17.3 UniversalRenderPipelineAsset layout."""
    if len(raw) < 68 or raw[28:40] != b"\x08\0\0\0URPAsset":
        return None
    if struct.unpack_from("<i", raw, 40)[0] != 13:
        raise ValueError("unexpected PEAK URP asset version")
    # The renderer list consists of 12-byte PPtrs. It precedes the fixed-size
    # pipeline settings ending at m_GPUResidentDrawerMode (an aligned UInt8).
    renderers = struct.unpack_from("<I", raw, 64)[0]
    position = 68 + 12 * renderers + 268
    if position >= len(raw) or raw[position] not in (0, 1):
        raise ValueError("unexpected PEAK GPU Resident Drawer mode")
    return position


def plan_serialized(read, size, name, graphics):
    header = read(0, 80)
    version_end = header.index(0, 48)
    if (struct.unpack_from(">I", header, 8)[0] != 22 or header[16] != 0 or
            header[48:version_end].split(b"\n")[0] != VERSION or
            struct.unpack_from(">Q", header, 24)[0] != size):
        raise ValueError(f"{name}: unsupported serialized header")
    platform = version_end + 1
    if struct.unpack_from("<i", header, platform)[0] != 19:
        raise ValueError(f"{name}: expected a Windows x86_64 serialized asset")
    edits = [(platform, struct.pack("<i", 2))]
    appended = bytearray()
    is_pipeline_file = name == "globalgamemanagers.assets"
    if graphics is None and name != "globalgamemanagers" and not is_pipeline_file:
        return edits, appended
    metadata_size = struct.unpack_from(">I", header, 20)[0]
    data_offset = struct.unpack_from(">Q", header, 32)[0]
    metadata = read(0, 48 + metadata_size)
    trees, types, count, pos = shader_types(metadata, platform + 4)
    if name != "globalgamemanagers" and not is_pipeline_file and not any(c in (48, 72, 141) for c, _ in types):
        return edits, appended
    settings_count = 0
    player_settings_count = 0
    pipeline_count = 0
    for index in range(count):
        entry = pos + index * 24
        _, relative, old_size, type_index = struct.unpack_from("<qqIi", metadata, entry)
        class_id, schema = types[type_index]
        offset = data_offset + relative
        if class_id == 129 and name == "globalgamemanagers":
            player_settings_count += 1
            if schema != PLAYER_SETTINGS_TYPE or old_size != 896:
                raise ValueError("unsupported PEAK PlayerSettings layout")
            # fullscreenMode in the supported 3.1.0 layout. Unity uses this default
            # on first launch and restores the player's saved window mode thereafter.
            mode_at = offset + 464
            mode = struct.unpack("<i", read(mode_at, 4))[0]
            if mode not in range(4):
                raise ValueError("unexpected Unity fullscreen mode")
            if mode != 1:
                edits.append((mode_at, struct.pack("<i", 1)))  # FullScreenWindow
        if is_pipeline_file and class_id == 114 and schema == URP_ASSET_TYPE:
            raw = read(offset, old_size)
            mode = urp_drawer_mode(raw)
            if mode is not None:
                pipeline_count += 1
                if raw[mode]:
                    edits.append((offset + mode, b"\0"))
        if class_id == 141 and name == "globalgamemanagers":
            settings_count += 1
            if read(offset + old_size - 16, 16) != struct.pack("<4i", 3, 18, 2, 21):
                raise ValueError("unexpected BuildSettings graphics API array")
            edits.extend([(entry + 16, struct.pack("<I", old_size - 8)),
                          (offset + old_size - 16, struct.pack("<4i", 1, 16, 0, 0))])
        if graphics is None or class_id not in (48, 72):
            continue
        raw = read(offset, old_size)
        new = graphics.convert(raw, class_id, schema, trees)
        if len(new) <= old_size:
            edits.append((offset, new))
            edits.append((entry + 16, struct.pack("<I", len(new))))
        else:
            appended.extend(bytes((-(size + len(appended))) % 8))
            new_pos = size + len(appended)
            edits.append((entry + 8, struct.pack("<qI", new_pos - data_offset, len(new))))
            appended.extend(new)
    if appended:
        edits.append((24, struct.pack(">Q", size + len(appended))))
    if name == "globalgamemanagers" and settings_count != 1:
        raise ValueError("expected one BuildSettings object")
    if name == "globalgamemanagers" and player_settings_count != 1:
        raise ValueError("expected one PlayerSettings object")
    if is_pipeline_file and pipeline_count != 1:
        raise ValueError("expected one supported PEAK URPAsset")
    return edits, appended


class Graphics:
    def __init__(self, work, vkd3d, cross):
        from metal_shaders import Toolchain
        self.tools = Toolchain(work / "msl", vkd3d, cross)
        self.schemas = {}
        self.objects = {}
        self.counts = Counter()

    def convert(self, raw, class_id, schema, embedded):
        from types import SimpleNamespace
        from UnityPy.files.SerializedFile import SerializedType
        from UnityPy.helpers import TypeTreeHelper
        from UnityPy.helpers.Tpk import get_typetree_node
        from UnityPy.helpers.UnityVersion import UnityVersion
        from UnityPy.streams import EndianBinaryReader, EndianBinaryWriter
        from metal_compute import convert_compute
        from metal_shaders import convert_shader

        key = (schema, hashlib.sha256(raw).digest())
        self.counts[class_id] += 1
        if key in self.objects:
            return self.objects[key]
        if schema not in self.schemas:
            if embedded:
                file = SimpleNamespace(header=SimpleNamespace(version=22), _enable_type_tree=True)
                node = SerializedType(EndianBinaryReader(schema, endian="<"), file, False).node
            else:
                node = get_typetree_node(class_id, UnityVersion.from_str(VERSION.decode()))
            self.schemas[schema] = node
        node = self.schemas[schema]
        tree = TypeTreeHelper.read_typetree(node, EndianBinaryReader(raw, endian="<"), byte_size=len(raw))
        try:
            result = (convert_shader if class_id == 48 else convert_compute)(tree, self.tools)
        except Exception as exc:
            label = tree.get("m_ParsedForm", {}).get("m_Name") or tree.get("m_Name")
            raise ValueError(f"{label}: {exc}") from exc
        writer = EndianBinaryWriter(endian="<")
        TypeTreeHelper.write_typetree(result, node, writer)
        self.objects[key] = writer.bytes
        return self.objects[key]


def convert_loose(path, dest, graphics):
    with path.open("rb") as source:
        size = os.fstat(source.fileno()).st_size
        def read(pos, length):
            source.seek(pos)
            return exact(source, length)
        edits, appended = plan_serialized(read, size, path.name, graphics)
        def write(out):
            source.seek(0)
            while chunk := source.read(1024 * 1024):
                out.write(chunk)
            out.write(appended)
            for pos, data in edits:
                out.seek(pos)
                out.write(data)
        atomic_write(dest, write)


def patch_map_glob(source, dest):
    # MapBundleService passes this #US literal directly to Directory.GetFiles.
    # The Windows pattern is mixed-case; the Steam bundle names are lowercase.
    assembly = Path("Managed") / "Assembly-CSharp.dll"
    target = dest / assembly
    if target.resolve() == (source / assembly).resolve():
        raise ValueError("staged game assembly aliases its source")
    data = (target if target.exists() else source / assembly).read_bytes()
    original = "*Levels*.assetBundle".encode("utf-16le")
    framed = bytes([len(original) + 1]) + original + b"\0"
    corrected = bytes([len(original) + 1]) + original.lower() + b"\0"
    if data.count(corrected) == 1 and framed not in data:
        return
    if data.count(framed) != 1 or corrected in data:
        raise ValueError("unexpected MapBundleService search pattern")
    atomic_write(target, lambda out: out.write(data.replace(framed, corrected)))


def prepare(source, dest, graphics):
    from unityfs_maps import convert_bundle
    source, dest = source.resolve(), dest.resolve()
    if (source == dest or source in dest.parents or dest in source.parents or
            not (source / "globalgamemanagers").is_file()):
        raise ValueError("provide separate source and staging directories for the Steam PEAK_Data layout")
    patch_map_glob(source, dest)
    files = [p for p in source.iterdir() if p.is_file() and (
        p.name == "globalgamemanagers" or p.suffix == ".assets" or re.fullmatch(r"level\d+", p.name))]
    files.append(source / "Resources" / "unity_builtin_extra")
    bundles = sorted(p for p in (source / "StreamingAssets").rglob("*") if p.is_file() and
                     (p.suffix == ".assetbundle" or p.name == "maps"))
    for p in [*sorted(files), *bundles]:
        rel = p.relative_to(source)
        target = dest / rel
        if target.resolve() == p.resolve():
            raise ValueError(f"target aliases input: {rel}")
        before = graphics.counts.copy() if graphics else Counter()
        if p in bundles:
            convert_bundle(p, target, plan_serialized, graphics)
        else:
            convert_loose(p, target, graphics)
        if graphics:
            counts = graphics.counts - before
            print(f"{rel}: {counts[48]} graphics, {counts[72]} compute shaders", flush=True)
    return len(files), len(bundles)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="Steam PEAK_Data")
    parser.add_argument("output", type=Path, help="private staged application Data directory")
    parser.add_argument("--metal-work", type=Path, help="private compiler cache for Metal conversion")
    parser.add_argument("--vkd3d", default="vkd3d-compiler")
    parser.add_argument("--spirv-cross", default="spirv-cross")
    args = parser.parse_args()
    graphics = Graphics(args.metal_work, args.vkd3d, args.spirv_cross) if args.metal_work else None
    loose, bundles = prepare(args.source, args.output, graphics)
    print(f"Retargeted {loose} loose assets and {bundles} UnityFS bundles.")
    if graphics:
        print(f"Converted {graphics.counts[48]} graphics and {graphics.counts[72]} compute shader objects.")


if __name__ == "__main__":
    main()
