"""Translate PEAK's shipped Vulkan compute variants to Unity Metal kernels."""

import copy
import hashlib
import re
import struct
import subprocess


KINDS = ("buffer", "texture", "sampler")
INDIRECT_ARGS = "8d24034985a4a35ab43d9e959b41876e322eac45bedab22cfdcc1d0d5731387a"


def resource_slots(kernel):
    """Rewrite Unity resource bindings and return the Vulkan-to-Metal correspondence."""
    slots = {}
    counts = dict.fromkeys(KINDS, 0)
    for group in ("outBuffers", "cbs", "inBuffers", "textures", "builtinSamplers"):
        for item in kernel[group]:
            if group == "builtinSamplers":
                kind = "sampler"
            elif group == "textures" or group == "outBuffers" and item["texDimension"] != -1:
                kind = "texture"
            else:
                kind = "buffer"
            encoded = item["bindPoint"]
            # Vulkan stores descriptor set and binding below its resource flags.
            descriptor = (encoded >> 16 & 0x7f, encoded & 0xffff)
            if descriptor in slots or item.get("samplerBindPoint", -1) != -1:
                raise ValueError(f"unsupported compute descriptor {descriptor}")
            slot = counts[kind]
            counts[kind] += 1
            slots[descriptor] = (kind, slot)
            item["bindPoint"] = slot
    # The Vulkan importer exposes append counters as extra storage buffers.
    # Unity Metal packs the counter slot + 1 in the high half of the owner's
    # bindPoint. The counter remains a real argument of the GPU program.
    outputs = {item["name"]: item for item in kernel["outBuffers"]}
    for name, counter in outputs.items():
        match = re.fullmatch(r"(.+)_origX\d+X_counterBuf", name)
        if match:
            owner = outputs[match[1]]
            owner["bindPoint"] |= (counter["bindPoint"] + 1) << 16
            kernel["outBuffers"].remove(counter)
    return slots


def remap_spirv(code, slots):
    if len(code) < 20 or len(code) % 4 or code[:4] != b"\x03\x02\x23\x07":
        raise ValueError("expected a little-endian SPIR-V compute module")
    words = list(struct.unpack(f"<{len(code) // 4}I", code))
    descriptors = {}
    pos = 5
    while pos < len(words):
        count, opcode = divmod(words[pos], 65536)
        if count == 0 or pos + count > len(words):
            raise ValueError("invalid SPIR-V instruction size")
        if opcode == 71 and count == 4:  # OpDecorate
            ident, decoration = words[pos + 1:pos + 3]
            if decoration in (33, 34):  # Binding, DescriptorSet
                fields = descriptors.setdefault(ident, {})
                if decoration in fields:
                    raise ValueError("duplicate SPIR-V descriptor decoration")
                fields[decoration] = pos + 3
        pos += count
    seen = set()
    for fields in descriptors.values():
        if len(fields) != 2:
            raise ValueError("incomplete SPIR-V resource binding")
        descriptor = (words[fields[34]], words[fields[33]])
        if descriptor not in slots or descriptor in seen:
            raise ValueError(f"SPIR-V binding disagrees with Unity metadata: {descriptor}")
        seen.add(descriptor)
        kind, slot = slots[descriptor]
        words[fields[34]] = KINDS.index(kind)
        words[fields[33]] = slot
    if seen != slots.keys():
        raise ValueError(f"unused Unity compute bindings: {slots.keys() - seen}")
    return struct.pack(f"<{len(words)}I", *words)


def lower_indirect_args(msl):
    # VFXFillIndirectArgs uses RWBuffer<uint>. Its Vulkan r32ui texel buffer
    # has a Metal device uint* counterpart, as in Unity's native compute import.
    declaration = rb"texture_buffer<uint, access::write> (\w+) \[\[texture\((\d+)\)\]\]"
    match = re.search(declaration, msl)
    if not match:
        raise ValueError("missing r32ui write target in VFXFillIndirectArgs")
    name, slot = match.groups()
    msl = msl[:match.start()] + b"device uint* " + name + b" [[buffer(" + slot + b")]]" + msl[match.end():]
    store = re.escape(name) + rb"\.write\(([^;\n]+), uint\(([\w.]+)\)\);"
    msl, count = re.subn(store, lambda m: name + b"[" + m[2] + b"] = (" + m[1] + b").x;", msl)
    if count != 8 or name + b"." in msl:
        raise ValueError("unexpected VFXFillIndirectArgs typed-buffer operation")
    return msl


def convert_compute(tree, toolchain):
    sources = [v for v in tree["variants"] if v["targetRenderer"] == 21]
    if len(sources) != 1:
        raise ValueError(f"{tree['m_Name']}: expected one Vulkan compute variant")
    metal = copy.deepcopy(sources[0])
    metal["targetRenderer"] = 16
    for entry in metal["kernels"]:
        for variant in entry["uniqueVariants"]:
            label = f"{tree['m_Name']}/{entry['name']}"
            slots = resource_slots(variant)
            original = bytes(variant["code"])
            spirv = remap_spirv(original, slots)
            result = subprocess.run(
                [str(toolchain.cross), "-", "--msl", "--msl-version", "20300",
                 "--msl-texture-buffer-native", "--msl-decoration-binding",
                 "--rename-entry-point", "main", "computeMain", "comp"],
                input=spirv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            )
            if result.returncode:
                detail = result.stderr.decode(errors="replace")[:1000].strip()
                raise ValueError(f"{label}: SPIRV-Cross failed: {detail}")
            msl = result.stdout
            if hashlib.sha256(original).hexdigest() == INDIRECT_ARGS:
                msl = lower_indirect_args(msl)
            bindings = re.findall(rb"\[\[\s*(buffer|texture|sampler)\((\d+)\)\s*\]\]", msl)
            actual = {(kind.decode(), int(slot)) for kind, slot in bindings}
            if actual != set(slots.values()) or b"kernel void computeMain(" not in msl:
                raise ValueError(f"{label}: generated Metal argument table differs from Unity metadata")
            # Metal compute header observed in the matching official player's Resources.
            header = struct.pack("<III4H", 0xDEADCAFE, 2, 20, *variant["threadGroupSize"], 1)
            variant["code"] = list(header + msl + b"\0")
    return dict(tree, variants=[metal])
