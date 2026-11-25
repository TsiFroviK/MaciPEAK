"""Cache PEAK's 30 macOS Mono assemblies from the official Unity Editor package."""
import argparse
import fcntl
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile


VERSION = "6000.3.15f1"
REVISION = "c1aa84e375f6"
URL = f"https://download.unity3d.com/download_unity/{REVISION}/MacEditorInstallerArm64/Unity-{VERSION}.pkg"
# The XAR member Unity.pkg.tmp/Payload begins with a gzip-compressed cpio stream.
# All files in the published manifest occur within this byte range of this exact Editor.
PREFIX_SIZE = 1_082_130_432
PREFIX_SHA256 = "e46fc2d796b7fb07487158286cb18b6a8107eb9ae898e523560e42599cbeb046"
PAYLOAD_OFFSET = 3_400_535
PROFILE = "./Unity/Unity.app/Contents/Resources/Scripting/MonoBleedingEdge/lib/mono/unityjit-macos"


def matches(root, manifest):
    for relative, digest in manifest.items():
        file = root / relative
        if not file.is_file() or hashlib.sha256(file.read_bytes()).hexdigest() != digest:
            return False
    return True


def fetch_prefix(output):
    print(f"Fetching the first {PREFIX_SIZE // (1 << 20)} MiB of Unity {VERSION} for its Mono profile…", file=sys.stderr)
    command = ["/usr/bin/curl", "--silent", "--show-error", "--fail", "--location",
               "--proto", "=https", "--proto-redir", "=https", "--connect-timeout", "30",
               "--speed-limit", "1024", "--speed-time", "90", "--range", f"0-{PREFIX_SIZE - 1}", URL]
    for attempt in range(3):
        digest = hashlib.sha256()
        count = 0
        # If a proxy ignores Range and returns HTTP 200, close the pipe at the same
        # known offset. The pinned prefix hash covers the XAR header and payload.
        with tempfile.TemporaryFile() as errors, subprocess.Popen(command, stdout=subprocess.PIPE, stderr=errors) as curl:
            try:
                with output.open("wb") as saved:
                    while count < PREFIX_SIZE:
                        block = curl.stdout.read(min(4 << 20, PREFIX_SIZE - count))
                        if not block:
                            break
                        digest.update(block)
                        skip = max(0, PAYLOAD_OFFSET - count)
                        saved.write(block[skip:])
                        count += len(block)
            finally:
                curl.stdout.close()
            curl.wait()
            if count == PREFIX_SIZE:
                if digest.hexdigest() != PREFIX_SHA256:
                    raise ValueError("the official Unity Editor does not match the pinned prefix checksum")
                return
            errors.seek(0)
            detail = errors.read().decode(errors="replace").strip()
        if attempt == 2:
            raise RuntimeError(f"Unity Editor download ended at byte {count}: {detail}")


def ensure(cache, manifest_file):
    manifest = {relative: mac for relative, _, mac in
                (line.split() for line in manifest_file.read_text("ascii").splitlines())}
    if len(manifest) != 30:
        raise ValueError("invalid Mono profile manifest")
    directory = cache / "unity" / REVISION
    directory.mkdir(parents=True, exist_ok=True)
    profile = directory / "unityjit-macos"
    with (directory / ".lock").open("a+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if matches(profile, manifest):
            return profile
        with tempfile.TemporaryDirectory(dir=directory, prefix=".extract-") as temp:
            stage = Path(temp)
            payload = stage / "profile.cpio.gz"
            fetch_prefix(payload)
            # BSD tar's -q stops after the first instance of every requested file.
            subprocess.run(["/usr/bin/tar", "-xqf", str(payload), "-C", str(stage),
                            *(f"{PROFILE}/{rel}" for rel in manifest)], check=True)
            extracted = stage / PROFILE
            if not matches(extracted, manifest):
                raise ValueError("Unity Mono assembly verification failed")
            for relative in manifest:
                dest = profile / relative
                dest.parent.mkdir(parents=True, exist_ok=True)
                (extracted / relative).replace(dest)
    return profile


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cache", type=Path)
    parser.add_argument("manifest", type=Path)
    args = parser.parse_args()
    print(ensure(args.cache.resolve(), args.manifest))
