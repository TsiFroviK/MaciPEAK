"""Retarget Unity-managed constant buffers from D3D packing to Metal uploads."""

from collections import defaultdict
from dataclasses import dataclass
import re


# The engine uploads these from reflected material/global properties. Other
# blocks can be supplied as pre-packed buffers by Unity or game scripts.
PROPERTY_BUFFERS = {"$Globals", "UnityPerMaterial"}


@dataclass(frozen=True)
class Field:
    name: str
    offset: int
    dimensions: int
    array_size: int


@dataclass(frozen=True)
class Definition:
    name: str
    size: int
    fields: tuple


def common_constants(common, names):
    definitions = []
    for buffer in common["m_ConstantBuffers"]:
        name = names[buffer["m_NameIndex"]]
        if name not in PROPERTY_BUFFERS:
            continue
        fields = [Field(names[f["m_NameIndex"]], f["m_Index"], f["m_Dim"], f["m_ArraySize"])
                  for f in buffer["m_VectorParams"]]
        for f in buffer["m_MatrixParams"] + buffer["m_StructParams"]:
            fields.append(Field(names[f["m_NameIndex"]], f["m_Index"], 0, 0))
        definitions.append(Definition(name, buffer["m_Size"], tuple(fields)))
    bindings = {names[f["m_NameIndex"]]: f["m_Index"] for f in common["m_ConstantBufferBindings"]}
    return definitions, bindings


class ConstantLayout:
    def __init__(self, definitions):
        self.sizes = {}
        self.offsets = {}
        groups = defaultdict(set)
        for d in definitions:
            if d.name in PROPERTY_BUFFERS:
                self.sizes[d.name] = max(self.sizes.get(d.name, 0), d.size)
                groups[d.name, d.size].update(d.fields)
        spans = {}
        selected = set()
        for (name, _), fields in groups.items():
            starts = {f.offset for f in fields}
            for f in fields:
                if f.dimensions != 3:
                    continue
                count = max(1, f.array_size)
                last = f.offset + (count - 1) * 16
                key = name, f.name
                spans[key] = max(spans.get(key, 0), count * 16)
                # A D3D float3 can share a register with the next parameter.
                # Unity's Metal uploader writes all four lanes of each vector.
                if f.offset % 16 or last + 12 in starts:
                    selected.add(key)
        for name, field_name in sorted(selected):
            span = spans[name, field_name]
            offset = (self.sizes[name] + 15) & ~15
            self.offsets[name, field_name] = offset
            self.sizes[name] = offset + span
        self.changed = {name for name, _ in self.offsets}
        if any(self.sizes[name] > 65536 for name in self.changed):
            raise ValueError("relocated shader constants exceed Metal's 64 KiB constant buffer")

    def common(self, common, names):
        for buffer in common["m_ConstantBuffers"]:
            name = names[buffer["m_NameIndex"]]
            if name in self.changed:
                buffer["m_Size"] = self.sizes[name]
                for f in buffer["m_VectorParams"]:
                    key = name, names[f["m_NameIndex"]]
                    if f["m_Dim"] == 3 and key in self.offsets:
                        f["m_Index"] = self.offsets[key]

    def program(self, definitions, bindings):
        by_slot = defaultdict(dict)
        for d in definitions:
            if d.name not in self.changed or d.name not in bindings:
                continue
            slot = bindings[d.name]
            for f in d.fields:
                key = d.name, f.name
                if f.dimensions != 3 or key not in self.offsets:
                    continue
                for element in range(max(1, f.array_size)):
                    for lane in range(3):
                        old = f.offset // 4 + 4 * element + lane
                        new = self.offsets[key] // 4 + 4 * element + lane
                        if by_slot[slot].setdefault(old, new) != new:
                            raise ValueError(f"overlapping input shader constants in {d.name}")
        return tuple((slot, tuple(sorted(words.items()))) for slot, words in sorted(by_slot.items()))


def rewrite_constants(msl, layouts):
    for slot, pairs in layouts:
        argument = re.search(r"constant (\w+)& (\w+) \[\[buffer\(" + str(slot) + r"\)\]\]", msl)
        if not argument:
            continue  # An optimized stage may have no reads of a declared CB.
        raw_type, arg = argument.groups()
        original = re.search(r"struct " + raw_type + r"\s*\{\s*float4 _m0\[(\d+)\];\s*\};", msl)
        if not original:
            raise ValueError(f"unsupported shader constant declaration for Metal slot {slot}")
        words = dict(pairs)
        size = max(int(original[1]), max(words.values()) // 4 + 1)
        typename = f"PeakConstantBuffer{slot}"
        base = f"{arg}._m0"
        msl = msl[:argument.start(1)] + typename + msl[argument.end(1):]
        regs = sorted({word // 4 for word in words})

        def vector(reg, source):
            parts = []
            for lane in range(4):
                old = 4 * reg + lane
                word = words.get(old, old)
                parts.append(f"{source}[{word // 4}u]." + "xyzw"[word % 4])
            return "float4(" + ", ".join(parts) + ")"

        # Static indices are used by almost every material shader. Inline their
        # constant offsets and reserve a logical-register reader for real loops.
        token = base + "["
        pieces = []
        start = 0
        dynamic = False
        for ref in re.finditer(r"\b" + re.escape(token), msl):
            if ref.start() < start:
                raise ValueError("nested dynamic accesses to the same constant buffer")
            end = ref.end()
            depth = 1
            while depth and end < len(msl):
                depth += (msl[end] == "[") - (msl[end] == "]")
                end += 1
            if depth:
                raise ValueError("unclosed shader constant access")
            idx = msl[ref.end():end - 1]
            if re.fullmatch(r"\d+u?", idx):
                reg = int(idx.rstrip("u"))
                replacement = vector(reg, base) if reg in regs else msl[ref.start():end]
            else:
                dynamic = True
                replacement = f"peak_read_{slot}({base}, {idx})"
            pieces.extend((msl[start:ref.start()], replacement))
            start = end
        pieces.append(msl[start:])
        msl = "".join(pieces)
        declarations = f"struct {typename} {{ float4 _m0[{size}]; }};\n"
        if dynamic:
            cases = "\n".join(f"case {r}u: return {vector(r, 'raw')};" for r in regs)
            declarations += (f"inline float4 peak_read_{slot}(constant float4* raw, uint index) {{\n"
                             f"switch (index) {{\n{cases}\ndefault: return raw[index];\n}}\n}}\n")
        msl = msl.replace("using namespace metal;", "using namespace metal;\n" + declarations, 1)
    return msl
