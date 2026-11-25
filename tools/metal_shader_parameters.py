"""Rewrite buffer binding indices in Unity 6000.3's packed shader parameters."""

import struct


def remap_parameters(original, stage, metal_slot):
    # The version precedes a list of constant-buffer definitions and a
    # resource binding table. The first definition can have an empty name.
    data = bytearray(original)
    framebuffer_inputs = []
    pos = 0

    def word():
        nonlocal pos
        value = struct.unpack_from("<I", data, pos)[0]
        pos += 4
        return value

    def read_name():
        nonlocal pos
        length = word()
        if length > len(data) - pos:
            raise ValueError("invalid Unity shader parameter name")
        start = pos
        pos += (length + 3) & ~3
        return data[start:start + length]

    def skip_variables():
        nonlocal pos
        for _ in range(word()):
            read_name()
            pos += 24

    if word() != 202012090:
        raise ValueError("unsupported Unity shader parameter format")
    for _ in range(word()):
        read_name()
        word()  # CB size
        skip_variables()
        for _ in range(word()):
            read_name()
            pos += 12  # offset, array size, stride
            skip_variables()
    for _ in range(word()):
        name = read_name()
        kind = word()
        if name.startswith(b"_UnityFBInput"):
            suffix = name[len(b"_UnityFBInput"):]
            if kind != 0 or stage != 24 or not suffix.isdigit() or int(suffix) > 7:
                raise ValueError("unexpected Unity framebuffer input")
            slot = struct.unpack_from("<I", data, pos)[0]
            framebuffer_inputs.append((slot, int(suffix)))
        if kind == 2:  # Structured, raw and typed read buffers (D3D SRV).
            old_slot = struct.unpack_from("<I", data, pos)[0]
            struct.pack_into("<I", data, pos, metal_slot(stage, "t", old_slot))
        widths = {0: 3, 1: 2, 2: 2, 4: 2}
        if kind not in widths:
            raise ValueError(f"unsupported Unity shader resource kind {kind}")
        pos += widths[kind] * 4
    if pos != len(data):
        raise ValueError("Unity shader parameter table length mismatch")
    return bytes(data), tuple(framebuffer_inputs)

def packed_constants(raw):
    """Read reflected property offsets and the buffer binding index of a variant."""
    from metal_constant_layout import Definition, Field, PROPERTY_BUFFERS
    from struct import unpack_from
    pos = 0

    def word():
        nonlocal pos
        value = unpack_from("<I", raw, pos)[0]
        pos += 4
        return value

    def name():
        nonlocal pos
        length = word()
        start = pos
        pos += (length + 3) & ~3
        return raw[start:start + length].decode("utf-8")

    if word() != 202012090:
        raise ValueError("unsupported Unity shader parameter format")
    definitions, bindings, sizes, offsets = [], {}, [], []
    for _ in range(word()):
        buffer = name()
        size_pos = pos
        size = word()
        fields = []
        for _ in range(word()):
            field = name()
            _, _, dim, matrix, count, off = unpack_from("<6I", raw, pos)
            if buffer in PROPERTY_BUFFERS:
                fields.append(Field(field, off, 0 if matrix else dim, count))
                if not matrix and dim == 3:
                    offsets.append((buffer, field, pos + 20))
            pos += 24
        for _ in range(word()):
            field = name()
            off = word()
            pos += 8
            fields.append(Field(field, off, 0, 0))
            for _ in range(word()):
                name()
                pos += 24
        if buffer in PROPERTY_BUFFERS:
            definitions.append(Definition(buffer, size, tuple(fields)))
            sizes.append((buffer, size_pos))
    for _ in range(word()):
        buffer = name()
        kind = word()
        widths = {0: 3, 1: 2, 2: 2, 4: 2}
        if kind == 1:
            bindings[buffer] = unpack_from("<I", raw, pos)[0]
        pos += 4 * widths[kind]
    if pos != len(raw):
        raise ValueError("invalid shader constant table")
    return definitions, bindings, sizes, offsets


def rewrite_packed_constants(raw, info, layout):
    _, _, sizes, offsets = info
    data = bytearray(raw)
    for buffer, pos in sizes:
        if buffer in layout.changed:
            struct.pack_into("<I", data, pos, layout.sizes[buffer])
    for buffer, field, pos in offsets:
        new = layout.offsets.get((buffer, field))
        if new is not None:
            struct.pack_into("<I", data, pos, new)
    return bytes(data)
