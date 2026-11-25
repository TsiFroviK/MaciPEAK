"""Adjust the Medium render scale in a staged PEAK 3.1.0 macOS app."""

import hashlib
import os
from pathlib import Path
import stat
import struct
import sys
import tempfile


# stage-graphics.sh has already normalized the map filename pattern for macOS.
STAGED_SHA256 = "5ff0321099a9d11b50619078d2fe490fcfeadafe3732df6c231d28cef3273deb"
PATCHED_SHA256 = "d09fe1eb2e01e9c0aa9bd770794104c74cefa14c20be76500dfe7d51c63badab"
# RenderScaleSetting.GetRenderScale, Medium arm in the pinned managed assembly.
MEDIUM_OPCODE_OFFSET = 0x4A358
STOCK_INSTRUCTION = b"\x22" + struct.pack("<f", 0.4)  # CIL ldc.r4
METAL_INSTRUCTION = b"\x22" + struct.pack("<f", 0.65)


def stage(assembly):
    expected_tail = ("Contents", "Resources", "Data", "Managed", "Assembly-CSharp.dll")
    if (assembly.parts[-5:] != expected_tail or assembly.parents[4].suffix != ".app"
            or assembly.resolve() != assembly.absolute()
            or not stat.S_ISREG(assembly.lstat().st_mode)):
        raise ValueError("expected a regular Assembly-CSharp.dll in a staged macOS app")
    data = assembly.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if digest == PATCHED_SHA256:
        print("Metal Medium render scale is already 65%.")
        return
    end = MEDIUM_OPCODE_OFFSET + len(STOCK_INSTRUCTION)
    if digest != STAGED_SHA256 or data[MEDIUM_OPCODE_OFFSET:end] != STOCK_INSTRUCTION:
        raise ValueError("unsupported PEAK 3.1.0 managed assembly")
    result = data[:MEDIUM_OPCODE_OFFSET] + METAL_INSTRUCTION + data[end:]
    if hashlib.sha256(result).hexdigest() != PATCHED_SHA256:
        raise ValueError("unexpected PEAK render scale patch result")

    # Replace the staged file without writing through another hard link.
    mode = stat.S_IMODE(assembly.stat().st_mode)
    with tempfile.NamedTemporaryFile(dir=assembly.parent, prefix=".render-scale-", delete=False) as output:
        temporary = Path(output.name)
        try:
            output.write(result)
            output.close()
            temporary.chmod(mode)
            os.replace(temporary, assembly)
        finally:
            temporary.unlink(missing_ok=True)
    print("Staged Metal Medium render scale at 65%.")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("Usage: stage-render-scale.py STAGED_APP/Contents/Resources/Data/Managed/Assembly-CSharp.dll")
    try:
        stage(Path(sys.argv[1]))
    except (OSError, ValueError) as error:
        sys.exit(f"Cannot stage the Metal render scale: {error}")
