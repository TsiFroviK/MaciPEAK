"""Check the Git index before publishing MaciPEAK. Uses only the standard library."""

import hashlib
import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BANNER = "docs/macipeak-banner.png"
BANNER_SHA256 = "187aba85befc973cb127ea3ef510257a44b0f0d21c5ec479682f3225d11dc5b5"
ICON = "gui/builder-icon.png"
ICON_SHA256 = "70f1ab28d4e94248cf7b448ef3f6e7a49e7cc26ce80988ed59cb2fc8b845aad6"
TOP_LEVEL = {
    ".gitattributes", ".gitignore", "build.sh", "LICENSE", "README.md",
    "README.ru.md", "THIRD_PARTY.md", ".github/workflows/check.yml",
    "gui/Builder.m", "gui/Info.plist", "gui/InstallUpdate.h", "gui/InstallUpdate.m",
    "gui/ReleaseUpdate.h", "gui/ReleaseUpdate.m", "gui/test-release-update.m", "gui/test-builder-language.m",
    "gui/test-install-update.m",
}
SOURCE_PATH = re.compile(
    r"(?:scripts/[\w.-]+\.(?:c|cs|m|mk|py|sh|sha256)"
    r"|tools/[\w.-]+\.py|licenses/[\w.-]+\.txt)", re.ASCII
)
BINARY_CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
CREDENTIALS = re.compile(
    r"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----"
    r"|\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b"
    r"|\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"
    r"|https?://[\w.%-]+:[^\s/@$]+@"
    r"|(?i:\b(?:пароль|password|passwd)\s*[:=]?\s+\d{3,}\b)"
    r"""|(?im:^\s*(?:export\s+)?["']?(?:password|passwd|api[_-]?key|"""
    r"""client[_-]?secret|secret[_-]?key|(?:access|github)[_-]?token|(?:ssh|steam)[_-]?password)["']?"""
    r"""\s*[:=]\s*(?:(["'])[A-Za-z0-9_~+!./=@%-]+\1|\d+\s*$))"""
)


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT)


def check_file(mode, oid, stage, name):
    if mode not in (b"100644", b"100755") or stage != b"0":
        return "expected a regular file with a resolved index entry"
    if name in (BANNER, ICON):
        content = git("cat-file", "blob", oid.decode("ascii"))
        expected = BANNER_SHA256 if name == BANNER else ICON_SHA256
        if mode != b"100644" or hashlib.sha256(content).hexdigest() != expected:
            return "unexpected MaciPEAK artwork"
        return None
    if name not in TOP_LEVEL and not SOURCE_PATH.fullmatch(name):
        return "path outside the published source list"
    try:
        source = git("cat-file", "blob", oid.decode("ascii")).decode("utf-8")
    except UnicodeDecodeError:
        return "expected UTF-8 source text"
    if BINARY_CONTROL.search(source) or source.startswith("version https://git-lfs.github.com/spec/v1"):
        return "binary content or a Git LFS pointer"
    if CREDENTIALS.search(source):
        return "possible embedded credential"
    return None


def main():
    if git("rev-parse", "--show-prefix").strip():
        sys.exit("Run this check in the MaciPEAK Git repository.")
    entries = git("ls-files", "--stage", "-z").split(b"\0")
    seen = set()
    errors = []
    for entry in entries:
        if not entry:
            continue
        metadata, raw_name = entry.split(b"\t", 1)
        name = raw_name.decode("utf-8", errors="backslashreplace")
        seen.add(name)
        problem = check_file(*metadata.split(), name)
        if problem:
            errors.append(f"{name}: {problem}")
    for required in ("build.sh", "gui/Builder.m", "scripts/package-gui.sh", "README.md", "README.ru.md", BANNER, ICON):
        if required not in seen:
            errors.append(f"{required}: missing from the Git index")
    if errors:
        sys.exit("\n".join(errors))
    print(f"Checked {len(seen)} files in the MaciPEAK Git index.")


if __name__ == "__main__":
    main()
