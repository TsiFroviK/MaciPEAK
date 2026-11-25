"""Read and rebuild PEAK streamed-scene bundles with bounded decompression."""
import bisect
import io
import os
import struct
from collections import defaultdict

from lz4.block import compress, decompress

from prepare_content import VERSION, atomic_write, cstring, exact


def align16(value):
    return (value + 15) & ~15


def decode(data, flags, size):
    codec = flags & 63
    if codec in (2, 3):
        return decompress(data, uncompressed_size=size)
    if codec == 0 and len(data) == size:
        return data
    raise ValueError(f"unsupported UnityFS compression {codec}")


class Bundle:
    def __init__(self, file):
        self.file = file
        if cstring(file) != b"UnityFS" or exact(file, 4) != struct.pack(">I", 8):
            raise ValueError("expected UnityFS v8")
        cstring(file)
        if cstring(file) != VERSION:
            raise ValueError("unexpected UnityFS engine revision")
        self.header_end = file.tell()
        total, packed, raw, flags = struct.unpack(">QIII", exact(file, 20))
        if flags & ~63 not in (0x240, 0x2c0) or total != os.fstat(file.fileno()).st_size:
            raise ValueError("unsupported UnityFS layout")
        first = align16(file.tell())
        end_index = bool(flags & 0x80)
        file.seek(total - packed if end_index else first)
        index = io.BytesIO(decode(exact(file, packed), flags, raw))
        self.data_start = first if end_index else align16(file.tell())
        index.seek(16)
        self.blocks = []
        self.offsets = []
        pos, logical = self.data_start, 0
        for _ in range(struct.unpack(">I", exact(index, 4))[0]):
            size, packed_size, codec = struct.unpack(">IIH", exact(index, 10))
            if size == 0 or size > 1024 * 1024:
                raise ValueError("unexpected UnityFS block size")
            self.blocks.append((pos, packed_size, size, codec))
            self.offsets.append(logical)
            pos += packed_size
            logical += size
        if pos != (total - packed if end_index else total):
            raise ValueError("UnityFS block table does not cover the data")
        self.nodes = []
        for _ in range(struct.unpack(">I", exact(index, 4))[0]):
            offset, size, attr = struct.unpack(">QQI", exact(index, 20))
            name = cstring(index)
            if offset + size > logical:
                raise ValueError("invalid UnityFS node bounds")
            self.nodes.append([offset, size, attr, name])
        self.changed = defaultdict(list)
        self.insert = defaultdict(list)
        self.last_block = (None, None)

    def block(self, n):
        if self.last_block[0] != n:
            pos, packed, size, codec = self.blocks[n]
            self.file.seek(pos)
            self.last_block = (n, decode(exact(self.file, packed), codec, size))
        return self.last_block[1]

    def read(self, pos, size):
        out = bytearray()
        while len(out) < size:
            n = bisect.bisect_right(self.offsets, pos) - 1
            start = pos - self.offsets[n]
            chunk = self.block(n)[start:start + size - len(out)]
            if not chunk:
                raise ValueError("invalid UnityFS read")
            out.extend(chunk)
            pos += len(chunk)
        return bytes(out)

    def plan(self, planner, graphics):
        shift = 0
        for node in sorted(self.nodes, key=lambda n: n[0]):
            offset, size, attr, name = node
            node[0] += shift
            if not attr & 4:
                continue
            edits, payload = planner(lambda pos, n: self.read(offset + pos, n), size, name.decode(), graphics)
            for local, value in edits:
                pos = offset + local
                consumed = 0
                while consumed < len(value):
                    i = bisect.bisect_right(self.offsets, pos) - 1
                    at = pos - self.offsets[i]
                    length = min(self.blocks[i][2] - at, len(value) - consumed)
                    if length <= 0:
                        raise ValueError("serialized edit is outside its UnityFS block")
                    self.changed[i].append((at, value[consumed:consumed + length]))
                    pos += length
                    consumed += length
            if payload:
                # Insert after the old serialized file; all offsets within
                # neighboring files remain relative to their own file start.
                end = offset + size
                i = bisect.bisect_right(self.offsets, end - 1) - 1
                self.insert[i].append((end - self.offsets[i], payload))
                node[1] += len(payload)
                shift += len(payload)

    def write(self, out):
        self.file.seek(0)
        out.write(exact(self.file, self.header_end))
        out.write(bytes(20))
        out.write(bytes(align16(out.tell()) - out.tell()))
        index = bytearray(20)

        def write_raw(data):
            for start in range(0, len(data), 128 * 1024):
                block = data[start:start + 128 * 1024]
                packed = compress(bytes(block), store_size=False)
                if len(packed) < len(block):
                    out.write(packed)
                    index.extend(struct.pack(">IIH", len(block), len(packed), 2))
                else:
                    out.write(block)
                    index.extend(struct.pack(">IIH", len(block), len(block), 0))

        for i, (pos, packed, size, codec) in enumerate(self.blocks):
            if i not in self.changed and i not in self.insert:
                self.file.seek(pos)
                out.write(exact(self.file, packed))
                index.extend(struct.pack(">IIH", size, packed, codec))
                continue
            data = bytearray(self.block(i))
            for start, value in self.changed[i]:
                data[start:start + len(value)] = value
            begin = 0
            for cut, payload in sorted(self.insert[i], key=lambda pair: pair[0]):
                write_raw(data[begin:cut])
                write_raw(payload)
                begin = cut
            write_raw(data[begin:])
        struct.pack_into(">I", index, 16, (len(index) - 20) // 10)
        index.extend(struct.pack(">I", len(self.nodes)))
        for offset, size, attr, name in self.nodes:
            index.extend(struct.pack(">QQI", offset, size, attr) + name + b"\0")
        out.write(index)
        total = out.tell()
        out.seek(self.header_end)
        out.write(struct.pack(">QIII", total, len(index), len(index), 0x2c0))


def convert_bundle(path, dest, planner, graphics):
    with path.open("rb") as source:
        bundle = Bundle(source)
        bundle.plan(planner, graphics)
        atomic_write(dest, bundle.write)
