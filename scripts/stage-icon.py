"""Build the Finder icon from the Windows executable's primary icon group."""

import struct
import subprocess
import sys
import tempfile
from pathlib import Path


def load_icons(executable):
    data = executable.read_bytes()
    if data[:2] != b"MZ":
        raise ValueError("Missing Windows executable header")
    pe, = struct.unpack_from("<I", data, 0x3C)
    if data[pe:pe + 4] != b"PE\0\0":
        raise ValueError("Missing PE header")
    sections, = struct.unpack_from("<H", data, pe + 6)
    optional_size, = struct.unpack_from("<H", data, pe + 20)
    optional = pe + 24
    magic, = struct.unpack_from("<H", data, optional)
    directories = {0x10B: 96, 0x20B: 112}[magic]
    resource_rva, resource_size = struct.unpack_from("<II", data, optional + directories + 16)
    section_table = optional + optional_size

    def file_offset(rva, size):
        for i in range(sections):
            start = section_table + 40 * i
            address, length, position = struct.unpack_from("<III", data, start + 12)
            delta = rva - address
            if 0 <= delta and delta + size <= length and position + delta + size <= len(data):
                return position + delta
        raise ValueError("Invalid PE resource address")

    base = file_offset(resource_rva, resource_size)
    tree = memoryview(data)[base:base + resource_size]

    def entries(directory, children):
        named, numbered = struct.unpack_from("<HH", tree, directory + 12)
        result = {}
        for i in range(named + numbered):
            key, offset = struct.unpack_from("<II", tree, directory + 16 + i * 8)
            if bool(offset >> 31) != children:
                raise ValueError("Unexpected PE resource directory depth")
            result[key] = offset & 0x7FFFFFFF
        return result

    def payload(entry):
        rva, length = struct.unpack_from("<II", tree, entry)
        start = file_offset(rva, length)
        return data[start:start + length]

    types = entries(0, True)
    groups = entries(types[14], True)  # RT_GROUP_ICON in Windows shell order
    group_languages = entries(next(iter(groups.values())), False)
    language, group_entry = next(iter(group_languages.items()))
    group = payload(group_entry)
    reserved, kind, count = struct.unpack_from("<HHH", group)
    if reserved or kind != 1 or len(group) != 6 + count * 14:
        raise ValueError("Invalid Windows icon group")
    images = entries(types[3], True)  # RT_ICON
    icons = {}
    for i in range(count):
        offset = 6 + i * 14
        width, height, _, _, _, depth, length, image_id = struct.unpack_from("<BBBBHHIH", group, offset)
        if width != height:
            continue
        languages = entries(images[image_id], False)
        raw = payload(languages.get(language, next(iter(languages.values()))))
        if len(raw) != length:
            raise ValueError("Icon payload length differs from its group")
        size = width or 256
        if size in icons and depth <= icons[size][0]:
            continue
        # An ICO directory uses a file offset in place of the PE resource ID.
        header = struct.pack("<HHH", 0, 1, 1) + group[offset:offset + 12] + struct.pack("<I", 22)
        icons[size] = depth, header + raw
    if not icons:
        raise ValueError("No square icon in the primary Windows icon group")
    return {size: icon for size, (_, icon) in icons.items()}


def stage(executable, app):
    icons = load_icons(executable)
    resources = app / "Contents/Resources"
    with tempfile.TemporaryDirectory() as temporary:
        work = Path(temporary)
        iconset = work / "PEAK.iconset"
        iconset.mkdir()
        for size, icon in icons.items():
            (work / f"{size}.ico").write_bytes(icon)
        for points in (16, 32, 128, 256, 512):
            for scale, suffix in ((1, ""), (2, "@2x")):
                pixels = points * scale
                source = min((size for size in icons if size >= pixels), default=max(icons))
                png = iconset / f"icon_{points}x{points}{suffix}.png"
                command = ["/usr/bin/sips", "-s", "format", "png"]
                if source != pixels:
                    command.extend(["-z", str(pixels), str(pixels)])
                subprocess.run([*command, work / f"{source}.ico", "--out", png],
                               stdout=subprocess.DEVNULL, check=True)
        subprocess.run(["/usr/bin/iconutil", "-c", "icns", iconset, "-o", resources / "PEAK.icns"], check=True)
    subprocess.run(["/usr/bin/plutil", "-replace", "CFBundleIconFile", "-string", "PEAK.icns",
                    app / "Contents/Info.plist"], check=True)
    print(f"Generated PEAK.icns from {len(icons)} Windows icon sizes (up to {max(icons)} px).")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("Usage: stage-icon.py WINDOWS_PEAK_EXE STAGED_APP")
    try:
        stage(Path(sys.argv[1]), Path(sys.argv[2]))
    except (KeyError, StopIteration, ValueError, OSError, struct.error) as error:
        sys.exit(f"Cannot stage the Windows game icon: {error}")
