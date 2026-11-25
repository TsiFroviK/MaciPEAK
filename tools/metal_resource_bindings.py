"""Lower vkd3d's DWORD texel-buffer emulation to Unity's native Metal buffers."""

import re


def remap_fragment_outputs(msl):
    """Use the color attachment indices assigned by Unity's native Metal pass."""
    # Unity 6000.3's Metal player specializes function constant 1 with eight
    # four-bit indices. Logical color 0 can be attachment 1 in a merged pass.
    pattern = r"(\[\[\s*)color\((\d+)\)"
    targets = sorted({int(n) for _, n in re.findall(pattern, msl)})
    if not targets:
        return msl
    if targets[-1] > 7 or "using namespace metal;" not in msl:
        raise ValueError("unsupported Metal fragment output declaration")
    declarations = ["constant uint32_t rp_output_remap_mask [[function_constant(1)]];"]
    for index in targets:
        declarations.append(f"constant uint rp_output_remap_{index} = "
                            f"(rp_output_remap_mask >> {index * 4}) & 0xF;")
    msl = msl.replace("using namespace metal;", "using namespace metal;\n" + "\n".join(declarations), 1)
    return re.sub(pattern, lambda m: f"{m[1]}color(rp_output_remap_{m[2]})", msl)


def metal_buffer_slot(stage, prefix, register):
    if prefix == "u":
        return register
    if prefix == "t" and stage in (23, 24):
        # Across the shipped buffer-using variants, Unity uses CB0..4 in a vertex
        # stage and CB0..11 in a fragment stage. Vertex streams also need slots.
        return (5 if stage == 23 else 12) + register
    raise ValueError(f"unsupported shader stage or resource: {stage}, {prefix}{register}")


def lower_buffer_resources(msl, stage):
    if "spvTexelBufferCoord(" not in msl:
        return msl
    loads = set(re.findall(r"\b([tu]\d+)\.read\(spvTexelBufferCoord\(", msl))
    stores = set(re.findall(r"\b([tu]\d+)\.write\((?=[^;\n]+spvTexelBufferCoord\()", msl))
    counters = set(re.findall(r"device atomic_uint\* (u\d+)_atomic \[\[buffer\(", msl))
    if not (loads | stores) or loads & stores:
        raise ValueError("unsupported texel-buffer access")
    for name in sorted(loads | stores):
        slot = metal_buffer_slot(stage, name[0], int(name[1:]))
        access = ", access::write" if name in stores else ""
        qualifier = "" if name in stores else "const "
        declaration = rf"texture2d<uint{access}> {name} \[\[texture\(\d+\)\]\]"
        msl, count = re.subn(declaration, f"{qualifier}device uint* {name} [[buffer({slot})]]", msl)
        if count != 1:
            raise ValueError(f"unexpected format for the {name} DWORD buffer")
        msl = msl.replace(f"{name}.read(spvTexelBufferCoord(", f"peakBufferRead({name}, uint(")
        if name in stores:
            msl = re.sub(rf"\b{name}\.write\(([^;\n]+), spvTexelBufferCoord\(",
                         rf"peakBufferWrite({name}, \g<1>, uint(", msl)
        if re.search(rf"\b{name}\s*\.", msl):
            raise ValueError(f"unrecognized {name} texel-buffer usage")
    # SPIRV-Cross emits both a texture and a backing atomic pointer for
    # image atomics. Unity actually supplies just the corresponding buffer.
    for name in counters:
        declaration = rf"texture2d<uint> {name} \[\[texture\(\d+\)\]\], "
        msl, count = re.subn(declaration, "", msl)
        if count != 1 or re.search(rf"\b{name}\b", msl):
            raise ValueError(f"unrecognized atomic buffer alias {name}")
        slot = metal_buffer_slot(stage, "u", int(name[1:]))
        msl = re.sub(rf"({name}_atomic \[\[buffer\()\d+\)", rf"\g<1>{slot})", msl)
    bindings = re.findall(r"\[\[buffer\((\d+)\)\]\]", msl)
    if len(set(bindings)) != len(bindings) or any(int(n) > 30 for n in bindings):
        raise ValueError("Metal argument buffer slots overlap or exceed the device limit")
    helpers = ""
    if loads:
        helpers += ("\nstatic inline uint4 peakBufferRead(const device uint* p, uint i)"
                    " { return uint4(p[i], 0u, 0u, 1u); }\n")
    if stores:
        helpers += ("\nstatic inline void peakBufferWrite(device uint* p, uint4 v, uint i)"
                    " { p[i] = v.x; }\n")
    return msl.replace("using namespace metal;", "using namespace metal;\n" + helpers, 1)
