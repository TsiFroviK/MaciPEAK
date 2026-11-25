"""Read Photon Voice native plugins from a user-supplied Unity package."""
import argparse
import hashlib
from pathlib import Path, PurePosixPath
import tarfile


def extract(package, output, windows_plugins):
    with tarfile.open(package, "r:*") as archive:
        files = {}
        members = {PurePosixPath(item.name): item for item in archive.getmembers()}
        for key, item in members.items():
            if key.name != "pathname" or not item.isfile() or item.size > 8192:
                continue
            asset = members.get(key.parent / "asset")
            if asset is None or not asset.isfile():
                continue
            name = archive.extractfile(item).read().decode("utf-8-sig").strip()
            path = PurePosixPath(name)
            if "photonvoicelibs" in {part.lower() for part in path.parts}:
                files[path] = asset

        def payload(entry):
            if entry.size > 32 << 20:
                raise ValueError(f"unexpected SDK payload for {entry.name}")
            return archive.extractfile(entry).read()

        for module in ("opus_egpv", "webrtc-audio"):
            expected = hashlib.sha256((windows_plugins / (module + ".dll")).read_bytes()).digest()
            peers = [entry for path, entry in files.items() if path.name.lower() == module + ".dll"]
            if not any(hashlib.sha256(payload(entry)).digest() == expected for entry in peers):
                raise ValueError(f"this SDK does not contain PEAK's Windows {module}.dll counterpart")
            for path, entry in files.items():
                suffix = f"{module}.bundle/Contents/MacOS/{module}"
                if path.name == module + ".bundle" or str(path).endswith(suffix) or path.name == "lib" + module + ".dylib":
                    data = payload(entry)
                    # Ignore the empty asset record for a serialized Unity folder.
                    if not data:
                        continue
                    target = output / ("lib" + module + ".dylib")
                    if target.exists() and target.read_bytes() != data:
                        raise ValueError(f"ambiguous {module} macOS SDK payloads")
                    target.write_bytes(data)
            if not (output / ("lib" + module + ".dylib")).exists():
                raise ValueError(f"the package has no matching macOS {module} plugin")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("windows_plugins", type=Path)
    args = parser.parse_args()
    extract(args.package, args.output, args.windows_plugins)
