"""Resolve a pinned dependency from --deps or a per-user download cache."""
import argparse
import fcntl
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(4 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def resolve(cache, deps, name, url, digest):
    if Path(name).name != name or len(digest) != 64 or not url.startswith("https://"):
        raise ValueError("invalid dependency specification")
    if deps and (Path(deps) / name).is_file():
        local = Path(deps) / name
        if sha256(local) != digest:
            raise ValueError(f"SHA-256 mismatch for local dependency {local}")
        return local.resolve()
    directory = cache / "downloads" / digest
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / name
    with (directory / ".lock").open("a+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if target.is_file() and sha256(target) == digest:
            return target
        with tempfile.NamedTemporaryFile(dir=directory, prefix=".download-", delete=False) as temporary:
            partial = Path(temporary.name)
        try:
            subprocess.run(["/usr/bin/curl", "--fail", "--location", "--show-error", "--silent",
                            "--retry", "3", "--connect-timeout", "30", "--proto", "=https",
                            "--proto-redir", "=https", "--output", str(partial), url], check=True)
            if sha256(partial) != digest:
                raise ValueError(f"SHA-256 mismatch for {name}")
            os.replace(partial, target)
        finally:
            partial.unlink(missing_ok=True)
    return target


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cache", type=Path)
    parser.add_argument("deps")
    parser.add_argument("name")
    parser.add_argument("url")
    parser.add_argument("sha256")
    args = parser.parse_args()
    print(resolve(args.cache.resolve(), args.deps, args.name, args.url, args.sha256))
