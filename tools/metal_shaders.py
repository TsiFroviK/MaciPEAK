"""Build Unity 6 Metal graphics programs from the game's compiled DXBC."""

import hashlib
import os
import re
import shutil
import struct
import subprocess
import tempfile
from pathlib import Path

from lz4.block import compress, decompress
from metal_resource_bindings import lower_buffer_resources, metal_buffer_slot, remap_fragment_outputs
from metal_shader_parameters import remap_parameters, packed_constants, rewrite_packed_constants
from metal_constant_layout import ConstantLayout, common_constants, rewrite_constants


METAL_KIND = {15: 23, 16: 23, 17: 24, 18: 24}
METAL_HEADER = struct.pack("<12I", 0xF00DCAFE, 48, 7, 60, 0, 0, 0, 0, 0, 37, 0xFFFFFFFF, 0)
CHANNEL = {"POSITION": 0, "NORMAL": 1, "TANGENT": 2, "COLOR": 3,
           "BLENDWEIGHT": 12, "BLENDWEIGHTS": 12, "BLENDINDICES": 13}


def dxbc_signature(dx, kind):
    count = struct.unpack_from("<I", dx, 28)[0]
    for offset in struct.unpack_from(f"<{count}I", dx, 32):
        signature = dx[offset:offset + 4]
        if signature not in (kind, kind[:3] + b"1"):
            continue
        start = offset + 8
        rows = struct.unpack_from("<I", dx, start)[0]
        result = {}
        for row in range(rows):
            row_offset = start + 8 + 24 * row if signature == kind else start + 12 + 32 * row
            name, index, _, _, reg, _ = struct.unpack_from("<6I", dx, row_offset)
            end = dx.index(b"\0", start + name)
            result[reg] = (dx[start + name:end].decode().upper(), index)
        return result
    return {}


class Toolchain:
    def __init__(self, cache, vkd3d, cross):
        self.vkd3d = vkd3d
        self.cross = cross
        # A local --deps override can select different translators on the same Mac.
        # Reuse raw translations only with the tools and Metal version that produced them.
        identity = hashlib.sha256(b"dxbc-tpf/spirv-binary/msl-20300")
        for command in (vkd3d, cross):
            executable = shutil.which(command)
            if executable is None:
                raise FileNotFoundError(command)
            identity.update(hashlib.sha256(Path(executable).read_bytes()).digest())
        self.cache = Path(cache) / identity.hexdigest()
        self.cache.mkdir(parents=True, exist_ok=True)

    def translate(self, dxbc):
        digest = hashlib.sha256(dxbc).hexdigest()
        output = self.cache / (digest + ".metal")
        if not output.exists():
            with tempfile.TemporaryDirectory(dir=self.cache) as temp:
                stage = Path(temp)
                shader = stage / "shader.dxbc"
                spv = stage / "shader.spv"
                metal = stage / "shader.metal"
                shader.write_bytes(dxbc)
                subprocess.run([self.vkd3d, "-x", "dxbc-tpf", "-b", "spirv-binary",
                                "-o", str(spv), str(shader)], check=True, capture_output=True)
                subprocess.run([self.cross, str(spv), "--msl", "--msl-version", "20300",
                                "--output", str(metal)], check=True, capture_output=True)
                os.replace(metal, output)
        return output.read_text(encoding="utf-8")


def framebuffer_copy(msl, inputs):
    # Unity supplies _UnityFBInput0 as an attachment in a native render pass.
    # Its emulation path on other GPUs supplies the original texture instead.
    if inputs != ((0, 0),):
        raise ValueError(f"unsupported framebuffer copy inputs: {inputs}")
    declaration = r"(texture2d(?:_ms)?(?:_array)?<float> t0 \[\[texture\(0\))\]\]"
    arguments = (r"float4 peak_framebuffer_color [[peak_input_color, function_constant(peak_fetch)]], "
                 r"\g<1>, function_constant(peak_emulate)]]")
    msl, declarations = re.subn(declaration, arguments, msl)
    msl, reads = re.subn(r"(out\.o0 = )(t0\.read\([^;\n]+\));",
                         r"\g<1>peak_fetch ? peak_framebuffer_color : \2;", msl)
    if declarations != 1 or reads != 1:
        raise ValueError("unexpected framebuffer copy program")
    constants = """
constant uint peak_input_remap [[function_constant(0)]];
constant uint peak_input_zero = peak_input_remap & 15u;
constant bool peak_fetch [[function_constant(2)]];
constant bool peak_emulate = !peak_fetch;
#if __METAL_VERSION__ >= 230
#define peak_input_color color(peak_input_zero)
#else
#define peak_input_color position
#endif
"""
    return msl.replace("using namespace metal;", "using namespace metal;\n" + constants, 1)


def metal_program(raw, tools, framebuffer_inputs=(), constants=()):
    version, kind = struct.unpack_from("<II", raw)
    if version != 202012090 or kind not in METAL_KIND:
        raise ValueError("unexpected DXBC program entry")
    pos = 28
    for _ in range(struct.unpack_from("<I", raw, 24)[0]):
        size = struct.unpack_from("<I", raw, pos)[0]
        pos = (pos + 4 + size + 3) & ~3
    original_size = struct.unpack_from("<I", raw, pos)[0]
    code = raw[pos + 4:pos + 4 + original_size]
    start = code.find(b"DXBC", 0, 256)
    if start < 0:
        raise ValueError("missing DXBC container")
    size = struct.unpack_from("<I", code, start + 24)[0]
    dx = code[start:start + size]
    if len(dx) != size:
        raise ValueError("truncated DXBC container")
    stage = METAL_KIND[kind]
    msl = tools.translate(dx)
    if ("vertex " if stage == 23 else "fragment ") not in msl:
        raise ValueError("MSL stage differs from the DXBC stage")
    msl = lower_buffer_resources(msl, stage)
    msl = rewrite_constants(msl, constants)
    if stage == 24:
        msl = remap_fragment_outputs(msl)
        if framebuffer_inputs:
            msl = framebuffer_copy(msl, framebuffer_inputs)
    else:
        # The matching Unity Metal compiler declares clip position invariant.
        # Depth and forward passes must rasterize the same transformed mesh.
        msl, changed = re.subn(r"(\bgl_Position\s*\[\[\s*)position(\s*\]\])",
                               r"\g<1>position, invariant\2", msl)
        if changed != 1:
            raise ValueError("expected one Metal vertex position output")
    msl = re.sub(r"\bmain0\b", "xlatMtlMain", msl)
    # Metal independently links vertex and fragment stage functions. DXBC
    # stages communicate by semantics, even when register locations differ.
    varying = dxbc_signature(dx, b"OSGN" if stage == 23 else b"ISGN")

    def varying_name(match):
        reg = int(match.group(1))
        if reg not in varying:
            return match.group()
        name, index = varying[reg]
        return "user(peak_" + name.lower() + str(index) + ")"

    msl = re.sub(r"\buser\(locn(\d+)\)", varying_name, msl)
    target = METAL_HEADER + b"xlatMtlMain\0" + msl.encode("utf-8")
    trailing = raw[(pos + 4 + original_size + 3) & ~3:]
    if stage == 23:
        inputs = dxbc_signature(dx, b"ISGN")
        channels = []
        for reg, attr in re.findall(r"\bv(\d+)\s*\[\[\s*attribute\((\d+)\)\s*\]\]", msl):
            name, index = inputs[int(reg)]
            if name == "TEXCOORD" and index < 8:
                channel = 4 + index
            elif name in CHANNEL and index == 0:
                channel = CHANNEL[name]
            else:
                raise ValueError(f"unsupported vertex channel {name}{index}")
            channels.append((channel, int(attr) + 13))
        channels.sort(key=lambda x: x[1])
        mask = sum(1 << x for x in {c for c, _ in channels})
        trailing = struct.pack("<II", mask, len(channels)) + b"".join(
            struct.pack("<II", channel, target_attr) for channel, target_attr in channels)
    header = bytearray(raw[:pos])
    struct.pack_into("<I", header, 4, stage)
    return bytes(header) + struct.pack("<I", len(target)) + target + bytes((-len(target)) % 4) + trailing


def convert_shader(tree, tools):
    if tree["platforms"] != [4, 18]:
        raise ValueError("expected the PEAK D3D and Vulkan program tables")
    blob = bytes(tree["compressedBlob"])
    segments = [decompress(blob[offset:offset + length], uncompressed_size=size)
                for offset, length, size in zip(tree["offsets"][0], tree["compressedLengths"][0],
                                                tree["decompressedLengths"][0])]
    count = struct.unpack_from("<I", segments[0])[0]
    entries = [struct.unpack_from("<III", segments[0], 4 + i * 12) for i in range(count)]
    programs = {}
    parameters = {}
    framebuffer_by_parameter = {}
    by_parameter_and_stage = {}
    extra_entries = []

    # A property's Metal offset must agree across all material passes. Start
    # after the largest original layout and collect both Unity metadata stores.
    definitions = set()
    packed_info = {}
    common_info = {}
    for sub in tree["m_ParsedForm"]["m_SubShaders"]:
        for pass_ in sub["m_Passes"]:
            names = {index: name for name, index in pass_["m_NameIndices"]}
            for name in ("Vertex", "Fragment"):
                group = pass_["prog" + name]
                common = common_constants(group["m_CommonParameters"], names)
                common_info[id(group)] = common
                definitions.update(common[0])
                for choices, indices in zip(group["m_PlayerSubPrograms"], group["m_ParameterBlobIndices"]):
                    for choice, index in zip(choices, indices):
                        if choice["m_GpuProgramType"] not in METAL_KIND or index in packed_info:
                            continue
                        start, size, segment = entries[index]
                        info = packed_constants(segments[segment][start:start + size])
                        packed_info[index] = info
                        definitions.update(info[0])
    layout = ConstantLayout(definitions)
    program_indices = {}

    def program_for(index, inputs, constants):
        key = index, inputs, constants
        if key not in program_indices:
            target = index
            if target in programs:
                target = count + len(extra_entries)
                extra_entries.append(None)
            programs[target] = key
            program_indices[key] = target
        return program_indices[key]

    def parameter_for(index, stage):
        key = (index, stage)
        if key in by_parameter_and_stage:
            return by_parameter_and_stage[key]
        start, size, segment = entries[index]
        old = segments[segment][start:start + size]
        new, framebuffer_inputs = remap_parameters(old, stage, metal_buffer_slot)
        if layout.changed:
            new = rewrite_packed_constants(new, packed_info[index], layout)
        if index in parameters and parameters[index] != new:
            # A shared source table can need different slots in the two
            # Metal stages. Give the second stage its own table.
            target_index = count + len(extra_entries)
            extra_entries.append(new)
        else:
            target_index = index
            parameters[index] = new
        by_parameter_and_stage[key] = target_index
        framebuffer_by_parameter[target_index] = framebuffer_inputs
        return target_index

    for sub in tree["m_ParsedForm"]["m_SubShaders"]:
        for pass_ in sub["m_Passes"]:
            names = {index: name for name, index in pass_["m_NameIndices"]}
            # The optional VR array-blit pass uses a geometry stage. The Mac
            # player has no Metal geometry stage; do not advertise this pass.
            geometry = any(pass_["progGeometry"]["m_PlayerSubPrograms"])
            for name in ("Vertex", "Fragment", "Geometry", "Hull", "Domain", "RayTracing"):
                program = pass_["prog" + name]
                groups = program["m_PlayerSubPrograms"]
                params = program["m_ParameterBlobIndices"]
                if name in ("Vertex", "Fragment"):
                    stage = 23 if name == "Vertex" else 24
                    common_defs, common_slots = common_info[id(program)]
                    layout.common(program["m_CommonParameters"], names)
                    for binding in program["m_CommonParameters"]["m_BufferParams"]:
                        binding["m_Index"] = metal_buffer_slot(stage, "t", binding["m_Index"])
                for i, choices in enumerate(groups):
                    if len(choices) != len(params[i]):
                        raise ValueError("shader choice and parameter tables differ")
                    selected = [(choice, p) for choice, p in zip(choices, params[i])
                                if not geometry and choice["m_GpuProgramType"] in METAL_KIND]
                    groups[i] = [choice for choice, _ in selected]
                    params[i] = [parameter_for(p, METAL_KIND[choice["m_GpuProgramType"]])
                                 for choice, p in selected]
                    for (choice, old_parameter), parameter in zip(selected, params[i]):
                        inputs = framebuffer_by_parameter[parameter]
                        constants = ()
                        if layout.changed:
                            local_defs, local_slots, _, _ = packed_info[old_parameter]
                            constants = layout.program(common_defs + local_defs, {**common_slots, **local_slots})
                        choice["m_BlobIndex"] = program_for(choice["m_BlobIndex"], inputs, constants)
                        choice["m_GpuProgramType"] = METAL_KIND[choice["m_GpuProgramType"]]
    total = count + len(extra_entries)
    result = bytearray(4 + 12 * total)
    struct.pack_into("<I", result, 0, total)
    for i in range(total):
        if i in programs:
            source, inputs, constants = programs[i]
            start, size, segment = entries[source]
            raw = metal_program(segments[segment][start:start + size], tools, inputs, constants)
        elif i in parameters:
            raw = parameters[i]
        elif i < count:
            start, size, segment = entries[i]
            raw = segments[segment][start:start + size]
        else:
            raw = extra_entries[i - count]
        struct.pack_into("<III", result, 4 + i * 12, len(result), len(raw), 0)
        result.extend(raw)
    packed = compress(bytes(result), store_size=False)
    tree.update(platforms=[14], offsets=[[0]], compressedLengths=[[len(packed)]],
                decompressedLengths=[[len(result)]], compressedBlob=packed,
                stageCounts=[min(2, tree["stageCounts"][0])])
    return tree
