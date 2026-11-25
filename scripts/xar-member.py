#!/usr/bin/env python3
"""Stream a stored member of a Unity macOS XAR installer to stdout."""

import os
import struct
import sys
import xml.etree.ElementTree as ET
import zlib


def stream_member(path, member, output):
    header = struct.Struct(">4sHHQQI")
    with open(path, "rb") as package:
        magic, length, version, packed, expanded, _ = header.unpack(package.read(header.size))
        if magic != b"xar!" or version != 1 or length < header.size:
            raise ValueError("invalid Unity XAR header")
        if max(packed, expanded) > 32 << 20:
            raise ValueError("XAR table of contents is too large")
        package.seek(length)
        table = zlib.decompress(package.read(packed))
        if len(table) != expanded:
            raise ValueError("incomplete XAR table of contents")
        node = ET.fromstring(table).find("toc")
        if node is None:
            raise ValueError("missing XAR table of contents")
        for part in member.split("/"):
            node = next((f for f in node.findall("file") if f.findtext("name") == part), None)
            if node is None:
                raise ValueError(f"missing XAR member {member}")
        data = node.find("data")
        encoding = node.find("data/encoding")
        if data is None or encoding is None or encoding.get("style") != "application/octet-stream":
            raise ValueError(f"expected a stored XAR member: {member}")
        offset = int(data.findtext("offset"))
        remaining = int(data.findtext("length"))
        start = length + packed + offset
        if offset < 0 or remaining < 0 or int(data.findtext("size")) != remaining:
            raise ValueError("invalid stored XAR member size")
        if start + remaining > os.fstat(package.fileno()).st_size:
            raise ValueError("invalid XAR member extent")
        package.seek(start)
        while remaining:
            chunk = package.read(min(4 << 20, remaining))
            if not chunk:
                raise ValueError("incomplete XAR member")
            output.write(chunk)
            remaining -= len(chunk)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: xar-member.py PACKAGE MEMBER")
    try:
        stream_member(sys.argv[1], sys.argv[2], sys.stdout.buffer)
    except (OSError, ValueError, struct.error, ET.ParseError, zlib.error) as exc:
        sys.exit(str(exc))
