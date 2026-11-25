"""Apply the PEAK native launch option to Steam's local application metadata."""

import hashlib
import struct
import zlib


APP_ID = 3527290
LAUNCH = "PEAK.app"
LEGACY_LAUNCH = "PEAK.app/Contents/MacOS/PEAK"
DESCRIPTION = "MaciPEAK (Metal)"
PLATFORM_FLAGS = ("macos", "macos64", "macosapplesilicon")


def uint(data, offset):
    return struct.unpack_from("<I", data, offset)[0]


def cache_path(appcache):
    shards = appcache / "appinfo"
    if shards.is_dir():
        # Steam distributes app ID records by the low byte of MurmurHash3 fmix32.
        h = APP_ID
        h = ((h ^ (h >> 16)) * 0x85ebca6b) & 0xffffffff
        h = ((h ^ (h >> 13)) * 0xc2b2ae35) & 0xffffffff
        shard = (h ^ (h >> 16)) & 255
        name = "appinfo_%02x.vdf" % shard
        return next((path for path in shards.glob("appinfo_*.vdf") if path.name.lower() == name), shards / name)
    return appcache / "appinfo.vdf"


def patch_cache(data, remove=False, apple_silicon=True):
    if data[:4] == b"*DV\x07":
        return patch_shard(data, remove, apple_silicon)
    if data[:8] != b")DV\x07\x01\x00\x00\x00":
        raise ValueError("Unsupported Steam appinfo cache format (expected v41 or v42).")
    table_at = struct.unpack_from("<Q", data, 8)[0]
    keys = data[table_at + 4:].split(b"\0")
    if keys.pop() != b"" or len(keys) != uint(data, table_at):
        raise ValueError("Invalid Steam appinfo key table.")
    cursor = 16
    while cursor + 8 <= table_at and uint(data, cursor):
        size = uint(data, cursor + 4)
        end = cursor + 8 + size
        if size < 62 or end > table_at:
            raise ValueError("Invalid Steam appinfo record length.")
        if uint(data, cursor) == APP_ID:
            break
        cursor = end
    else:
        if remove:
            return data
        raise ValueError("Open the owned PEAK library page in Steam, then quit Steam and retry.")
    start = cursor + 68
    raw = data[start:end]
    if hashlib.sha1(raw).digest() != data[start - 20:start]:
        raise ValueError("PEAK's cached Steam record is incomplete. Open its Steam library page and retry.")
    new = patch_record(raw, keys, remove, apple_silicon)
    if new == raw:
        return data
    delta = len(new) - len(raw)
    output = bytearray(data[:start])
    struct.pack_into("<Q", output, 8, table_at + delta)
    struct.pack_into("<I", output, cursor + 4, size + delta)
    output[start - 20:start] = hashlib.sha1(new).digest()
    output.extend(new)
    output.extend(data[end:table_at])
    output.extend(struct.pack("<I", len(keys)))
    output.extend(b"\0".join(keys) + b"\0")
    return bytes(output)


def patch_shard(data, remove, apple_silicon):
    fields = list(struct.unpack_from("<11I", data))
    magic, universe, shard, count, napps, index_size, nkeys, key_size, data_size, index_crc, header_crc = fields
    key_at = 44 + index_size
    data_at = key_at + key_size
    if (universe != 1 or shard >= count or data_at + data_size != len(data)
            or zlib.crc32(data[:40]) != header_crc or zlib.crc32(data[44:data_at]) != index_crc):
        raise ValueError("Invalid Steam appinfo shard header or checksum.")
    entries = bytearray(data[44:key_at])
    keys = data[key_at:data_at].split(b"\0")
    if keys.pop() != b"" or len(keys) != nkeys:
        raise ValueError("Invalid Steam appinfo shard key table.")
    index = []
    pos = 0
    for _ in range(napps):
        app_id, offset, size, summary_size = struct.unpack_from("<4I", entries, pos)
        if size < 20 or offset + size > data_size:
            raise ValueError("Invalid Steam appinfo shard record.")
        index.append((app_id, offset, size, pos))
        pos += 16 + summary_size
    if pos != index_size:
        raise ValueError("Invalid Steam appinfo shard index.")
    match = [row for row in index if row[0] == APP_ID]
    if not match:
        if remove:
            return data
        raise ValueError("Open the owned PEAK library page in Steam, then quit Steam and retry.")
    if len(match) != 1:
        raise ValueError("Duplicate PEAK appinfo record.")
    _, old_at, old_size, record_pos = match[0]
    data_entry = data_at + old_at
    end = data_entry + old_size
    raw = data[data_entry + 20:end]
    if hashlib.sha1(raw).digest() != data[data_entry:data_entry + 20]:
        raise ValueError("Invalid PEAK shard record checksum.")
    new = patch_record(raw, keys, remove, apple_silicon)
    if new == raw:
        return data
    delta = len(new) - len(raw)
    for _, offset, _, pos in index:
        if offset > old_at:
            struct.pack_into("<I", entries, pos + 4, offset + delta)
    struct.pack_into("<I", entries, record_pos + 8, old_size + delta)
    key_blob = b"\0".join(keys) + b"\0"
    fields[6:10] = [len(keys), len(key_blob), data_size + delta, zlib.crc32(entries + key_blob)]
    fields[10] = zlib.crc32(struct.pack("<10I", *fields[:10]))
    return (struct.pack("<11I", *fields) + entries + key_blob + data[data_at:data_entry]
            + hashlib.sha1(new).digest() + new + data[end:])


def patch_record(raw, keys, remove, apple_silicon):
    # Only the PEAK record is decoded. Preserve types, key indices, ordering and
    # original bytes of scalar values, including all other apps and depot data.
    pos = 0
    def read_object():
        nonlocal pos
        entries = {}
        while pos < len(raw) and raw[pos] != 8:
            kind = raw[pos]
            index = uint(raw, pos + 1)
            name = keys[index].decode("utf-8")
            if name in entries:
                raise ValueError("Duplicate field in PEAK appinfo.")
            pos += 5
            if kind == 0:
                value = read_object()
            else:
                if kind == 1:
                    stop = raw.index(b"\0", pos) + 1
                elif kind in (2, 3, 4, 6, 7, 10):
                    stop = pos + (8 if kind in (7, 10) else 4)
                else:
                    raise ValueError("Unsupported field type in PEAK appinfo: %s" % kind)
                value, pos = raw[pos:stop], stop
            entries[name] = (kind, value)
        if pos >= len(raw):
            raise ValueError("Truncated PEAK appinfo.")
        pos += 1
        return entries
    tree = read_object()
    if pos != len(raw):
        raise ValueError("Unexpected data after PEAK appinfo.")
    string = lambda value: (1, value.encode("utf-8") + b"\0")
    info = tree["appinfo"][1]
    common = info["common"][1]
    config = info["config"][1]
    public_build = info["depots"][1]["branches"][1]["public"][1]["buildid"]
    if public_build[0] == 2:
        build = uint(public_build[1], 0)
    else:
        build = int(public_build[1].rstrip(b"\0"))
    if not remove and build != 26542162:
        raise ValueError("Steam's current public PEAK build %s differs from MaciPEAK's supported build 26542162." % build)
    if common["name"] != string("PEAK") or config["installdir"] != string("PEAK"):
        raise ValueError("Unexpected PEAK game identity or install directory.")
    if "osextended" not in common:
        raise ValueError("Missing PEAK platform metadata. Refresh the PEAK library page in Steam.")
    choices = config["launch"][1]
    def launch_entry(path, preserved):
        # A self-contained local receipt on the launch option distinguishes
        # platform flags the user already had. Steam displays "description".
        entry = {"executable": string(path), "type": string("default"),
                 "config": (0, {"oslist": string("macos")}), "description": string(DESCRIPTION)}
        if preserved:
            entry["name"] = string("MaciPEAK/preserve=" + ",".join(preserved))
        return entry

    def own_entry(entry):
        receipt = entry.get("name", string(""))[1].rstrip(b"\0")
        if receipt and not receipt.startswith(b"MaciPEAK/preserve="):
            return None
        flags = receipt[len(b"MaciPEAK/preserve="):].decode("ascii").split(",") if receipt else []
        if any(flag not in PLATFORM_FLAGS for flag in flags):
            return None
        for path in (LAUNCH, LEGACY_LAUNCH):
            if entry == launch_entry(path, flags):
                return path, flags
        return None

    ours = [(key, own_entry(entry)) for key, (_, entry) in choices.items()]
    ours = [(key, local) for key, local in ours if local is not None]
    if len(ours) > 1:
        raise ValueError("Multiple MaciPEAK launch options in the Steam cache.")
    def labels(entry, name):
        value = entry.get(name, string(""))[1].rstrip(b"\0").decode("ascii")
        return value.split(",") if value else []
    def has_macos(choice):
        return "macos" in labels(choice[1].get("config", (0, {}))[1], "oslist")
    oses = labels(common, "oslist")
    extended = labels(common, "osextended")
    if ours:
        key, (path, preserved) = ours[0]
        if path == LEGACY_LAUNCH and "macosapplesilicon" in extended and "macosapplesilicon" not in preserved:
            # The binary-launch installer never set this Apple silicon flag.
            preserved.append("macosapplesilicon")
    else:
        preserved = [flag for flag in PLATFORM_FLAGS if flag in oses + extended]
    if remove:
        if not ours:
            return raw
        del choices[key]
        if not any(has_macos(choice) for choice in choices.values()):
            oses = [name for name in oses if name != "macos" or name in preserved]
            extended = [flag for flag in extended if flag not in PLATFORM_FLAGS or flag in preserved]
    else:
        if "macos" not in oses:
            oses.append("macos")
        requested = ("macos64", "macosapplesilicon") if apple_silicon else ("macos64",)
        if ours and "macosapplesilicon" not in preserved and not apple_silicon:
            extended = [flag for flag in extended if flag != "macosapplesilicon"]
        for flag in requested:
            if flag not in extended:
                extended.append(flag)
        if not ours:
            if any(has_macos(choice) for choice in choices.values()):
                raise ValueError("PEAK already defines another Mac launch target. Review it in Steam.")
            # Reuse a key already in this shard's table. Removing this local
            # choice can then restore the full original file byte for byte.
            available = sorted(int(k) for k in keys if k.isdigit() and k.decode() not in choices
                               and len(k) < 4 and k == str(int(k)).encode())
            if not available:
                raise ValueError("Steam's cached PEAK launch table has no free numeric option.")
            key = str(available[0])
        choices[key] = (0, launch_entry(LAUNCH, preserved))
    common["oslist"] = string(",".join(oses))
    common["osextended"] = string(",".join(extended))
    indexes = {key: i for i, key in enumerate(keys)}
    def encode(entries):
        out = bytearray()
        for name, (kind, value) in entries.items():
            key = name.encode("utf-8")
            if key not in indexes:
                raise ValueError("Incomplete Steam PEAK launch key table.")
            out += struct.pack("<BI", kind, indexes[key])
            out += encode(value) if kind == 0 else value
        out.append(8)
        return out
    return bytes(encode(tree))
