"""Install MaciPEAK in a Steam library and register the real PEAK library entry."""

import argparse
import contextlib
import hashlib
import os
from pathlib import Path
import plistlib
import re
import secrets
import stat
import struct
import subprocess
import sys
import tempfile

from steam_appinfo import APP_ID, cache_path, patch_cache


APP = str(APP_ID)
MANIFEST = "appmanifest_%s.acf" % APP
MARKER = ".macipeak-steam-manifest"
MARKER_CONTENT = b"MaciPEAK local install v1\n"
SUPPORTED_BUILD = "26542162"
SUPPORTED_VERSION = "3.1.0"
ARCHITECTURES = {"arm64": {"arm64"}, "x86_64": {"x86_64"}, "universal": {"arm64", "x86_64"}}
TOKEN = re.compile(r'\s+|//[^\r\n]*|"(?:\\.|[^"\\])*"|[{}]')


def quoted(value):
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"'


def parse(text):
    """Read quoted Valve KeyValues; retain source offsets for scoped insertions."""
    tokens = []
    pos = 0
    while pos < len(text):
        m = TOKEN.match(text, pos)
        if not m:
            raise ValueError("Unsupported Steam library configuration syntax.")
        tok, pos = m[0], m.end()
        if not tok.isspace() and not tok.startswith("//"):
            tokens.append((tok, m.start(), pos))
    idx = 0
    def value():
        nonlocal idx
        token, begin, end = tokens[idx]
        idx += 1
        if token == "{":
            items = {}
            while tokens[idx][0] != "}":
                key = value()[0]
                if not isinstance(key, str) or key in items:
                    raise ValueError("Duplicate or invalid KeyValues field.")
                items[key] = value()
            end = tokens[idx][2]
            idx += 1
            return items, begin, end
        if not token.startswith('"'):
            raise ValueError("Expected a quoted KeyValues value.")
        return re.sub(r'\\(["\\])', r'\1', token[1:-1]), begin, end
    root = {}
    while idx < len(tokens):
        key = value()[0]
        if key in root:
            raise ValueError("Duplicate Steam root field.")
        root[key] = value()
    return root


def document(raw):
    return raw.decode("utf-8-sig")


def read_libraries(raw):
    root = parse(document(raw))["libraryfolders"]
    libs = {}
    for index, (entry, _, _) in root[0].items():
        if not index.isdigit():
            continue
        if not isinstance(entry, dict) or "path" not in entry:
            raise ValueError("Unsupported Steam libraryfolders entry.")
        path = Path(entry["path"][0]).expanduser()
        if not path.is_absolute() or path in libs:
            raise ValueError("Duplicate or invalid Steam library path.")
        libs[path] = (index, entry)
    return root, libs


def library_files(steam):
    files = [p for p in (steam / "steamapps/libraryfolders.vdf", steam / "config/libraryfolders.vdf") if p.is_file()]
    if not files:
        raise ValueError("Start Steam once and sign in so its library list exists.")
    return files


def native_executable(app):
    if app.resolve() != app:
        raise ValueError("The MaciPEAK application is redirected by a symlink: %s" % app)
    executable = app / "Contents/MacOS/PEAK"
    plist_path = app / "Contents/Info.plist"
    if executable.resolve() != executable or plist_path.resolve() != plist_path:
        raise ValueError("The MaciPEAK application contains a redirected executable or Info.plist: %s" % app)
    plist = plistlib.loads(plist_path.read_bytes())
    if (not isinstance(plist, dict) or plist.get("CFBundleIdentifier") != "local.peak.macport"
            or plist.get("CFBundleExecutable") != "PEAK"
            or plist.get("CFBundleShortVersionString") != SUPPORTED_VERSION or not executable.is_file()):
        raise ValueError("Expected a complete MaciPEAK %s application at %s" % (SUPPORTED_VERSION, app))
    return executable


def has_maci_peak(folder):
    try:
        native_executable(folder / "steamapps/common/PEAK/PEAK.app")
    except (OSError, ValueError):
        return False
    return True


def installed_architectures(app, expected=None):
    executable = native_executable(app)
    result = subprocess.run(["/usr/bin/lipo", "-archs", str(executable)], capture_output=True, text=True)
    architectures = set(result.stdout.split())
    if result.returncode or not architectures or not architectures <= ARCHITECTURES["universal"]:
        raise ValueError("Could not read the PEAK executable's supported architectures.")
    if expected and not ARCHITECTURES[expected] <= architectures:
        raise ValueError("The existing PEAK.app has %s. To build for %s, move that app out of the Steam directory first."
                         % (", ".join(sorted(architectures)), expected))
    return architectures


def choose_library(steam, requested, raw):
    _, libs = read_libraries(raw)
    installed = [p for p, (_, entry) in libs.items()
                 if (p / "steamapps" / MANIFEST).is_file() or APP in entry.get("apps", ({},))[0]]
    if requested:
        folder = Path(requested).expanduser().resolve()
        if folder.name == "steamapps":
            raise ValueError("--steam-library expects the library root containing steamapps.")
        if folder.parts[1:2] == ("Volumes",) and (len(folder.parts) < 3 or not Path(*folder.parts[:3]).is_mount()):
            raise ValueError("The selected external Steam library volume is not mounted.")
    elif installed:
        folder = installed[0]
    else:
        candidates = [path for path in libs if has_maci_peak(path)]
        if len(candidates) > 1:
            raise ValueError("Found more than one unregistered MaciPEAK app. Choose its Steam library with --steam-library.")
        folder = candidates[0] if candidates else steam
    if any(p.resolve() != folder for p in installed):
        raise ValueError("PEAK is registered in another Steam library: %s" % ", ".join(map(str, installed)))
    if not requested and not folder.is_dir():
        raise ValueError("Mount PEAK's existing Steam library: %s" % folder)
    if folder == Path("/") or any(c in str(folder) for c in "\r\n\x00"):
        raise ValueError("Invalid Steam library location.")
    if folder not in libs and any(folder == parent or folder in parent.parents or parent in folder.parents for parent in libs):
        raise ValueError("A new Steam library must be separate from existing library directories.")
    base = folder / "steamapps/common/PEAK"
    if base.resolve() != base:
        raise ValueError("The Steam game directory is redirected by a symlink.")
    return folder


def library_update(raw, folder, content_id, size, remove=False, label=""):
    text = document(raw)
    root, libs = read_libraries(raw)
    if folder not in libs:
        if remove:
            return raw
        index = str(max((int(v[0]) for v in libs.values()), default=-1) + 1)
        body = ('\t"%s"\n\t{\n\t\t"path"\t\t%s\n\t\t"label"\t\t%s\n\t\t"contentid"\t\t"%s"\n'
                '\t\t"totalsize"\t\t"0"\n\t\t"apps"\n\t\t{\n\t\t\t"%s"\t\t"%s"\n\t\t}\n\t}\n'
                % (index, quoted(folder), quoted(label), content_id, APP, size))
        start = root[2] - 1
        text = text[:start] + body + text[start:]
    else:
        entry = libs[folder][1]
        apps = entry["apps"]
        if APP in apps[0]:
            if not remove:
                return raw
            _, value_start, stop = apps[0][APP]
            # Locate exactly the matched key/value, excluding adjacent fields.
            key_start = text.rfind(quoted(APP), apps[1], value_start)
            assert key_start >= apps[1]
            text = text[:key_start] + text[stop:]
        elif remove:
            return raw
        else:
            start = apps[2] - 1
            text = text[:start] + '\t"%s"\t\t"%s"\n\t\t' % (APP, size) + text[start:]
    new = (b"\xef\xbb\xbf" if raw.startswith(b"\xef\xbb\xbf") else b"") + text.encode()
    _, result = read_libraries(new)
    if folder not in result or (APP in result[folder][1]["apps"][0]) == remove:
        raise ValueError("Failed to verify Steam library registration.")
    return new


def new_manifest(size):
    return ('"AppState"\n{\n\t"appid" "%s"\n\t"universe" "1"\n\t"name" "PEAK"\n'
            '\t"StateFlags" "4"\n\t"installdir" "PEAK"\n\t"SizeOnDisk" "%s"\n'
            '\t"buildid" "%s"\n\t"AutoUpdateBehavior" "0"\n}\n'
            % (APP, size, SUPPORTED_BUILD)).encode()


def replace(path, data):
    if data is None:
        path.unlink()
        return
    fd, name = tempfile.mkstemp(prefix=".macipeak-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as out:
            out.write(data)
            if path.exists():
                os.fchmod(out.fileno(), stat.S_IMODE(path.stat().st_mode))
            out.flush()
            os.fsync(out.fileno())
        os.replace(name, path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(name)


def register(steam, requested, files, remove, expected_arch=None):
    import fcntl
    fd = os.open(str(steam), os.O_RDONLY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        if subprocess.run(["/usr/bin/pgrep", "-u", str(os.getuid()), "-x", "steam_osx"], stdout=subprocess.DEVNULL).returncode != 1:
            raise ValueError("Quit Steam before updating its local library configuration.")
        old = {file: file.read_bytes() for file in files}
        folder = choose_library(steam, requested, old[files[0]])
        base = folder / "steamapps/common/PEAK"
        app = base / "PEAK.app"
        apple_silicon = not remove and "arm64" in installed_architectures(app, expected_arch)
        cache = cache_path(steam / "appcache")
        old[cache] = cache.read_bytes()
        changes = {cache: patch_cache(old[cache], remove, apple_silicon=apple_silicon)}
        manifest = folder / "steamapps" / MANIFEST
        marker = base / MARKER
        old[manifest] = manifest.read_bytes() if manifest.exists() else None
        old[marker] = marker.read_bytes() if marker.exists() else None
        owned = old[marker] == MARKER_CONTENT
        if old[marker] is not None and not owned:
            raise ValueError("An unknown file occupies the MaciPEAK install marker path.")
        repair_manifest = False
        if old[manifest] is not None:
            state = parse(document(old[manifest]))["AppState"][0]
            if state["appid"][0] != APP or state["installdir"][0] != "PEAK":
                raise ValueError("Unexpected existing PEAK app manifest.")
            installed_depots = state.get("InstalledDepots", ({},))[0]
            if not remove:
                build = state["buildid"][0]
                flags = int(state["StateFlags"][0])
                target = state.get("TargetBuildID", (build,))[0]
                # Steam can retain the pending Windows download after a user
                # turns compatibility off. Restore only our own empty manifest.
                update_progress = 0x100 | 0x200 | 0x400  # queued, paused, started
                repair_manifest = (owned and installed_depots == {} and (flags & ~update_progress) == 0x6
                                   and target in ("0", SUPPORTED_BUILD))
                if build != SUPPORTED_BUILD or (flags != 4 and not repair_manifest):
                    raise ValueError("The existing Steam PEAK install has a pending or different build.")
            # A subsequent regular Steam installation may adopt this directory.
            # Preserve its manifest and library membership when removing MaciPEAK.
            if remove and owned and installed_depots:
                changes[marker] = None
                owned = False
        size = 0 if remove else sum(p.stat().st_size for p in app.rglob("*") if not p.is_symlink() and p.is_file())
        disk_record = folder / "libraryfolder.vdf"
        content_ids = set()
        label = ""
        if disk_record.is_file():
            descriptor = parse(document(disk_record.read_bytes()))["libraryfolder"][0]
            content_ids.add(descriptor["contentid"][0])
            label = descriptor.get("label", ("",))[0]
        for file in files:
            _, libs = read_libraries(old[file])
            if folder in libs:
                content_ids.add(libs[folder][1]["contentid"][0])
        if len(content_ids) > 1 or any(not tag.isdigit() or not 0 < int(tag) < 2**64 for tag in content_ids):
            raise ValueError("Steam library content IDs on disk and in the client must match.")
        content_id = next(iter(content_ids), str(secrets.randbits(63) or 1))
        if not remove or owned:
            for file in files:
                changes[file] = library_update(old[file], folder, content_id, size, remove, label)
            if not remove and (old[manifest] is None or repair_manifest):
                changes[marker] = MARKER_CONTENT
                changes[manifest] = new_manifest(size)
            if remove and owned:
                changes[manifest] = changes[marker] = None
        applied = []
        for file in changes:
            if file.is_symlink():
                raise ValueError("Refusing to replace a symlink: %s" % file)
        backup = folder / ".macipeak-steam-backup"
        try:
            for file, data in changes.items():
                if data == old[file]:
                    continue
                if file.exists() and file.read_bytes() != old[file] or not file.exists() and old[file] is not None:
                    raise ValueError("Steam configuration changed during registration. Quit Steam and retry.")
                if old[file] is not None:
                    backup.mkdir(mode=0o700, exist_ok=True)
                    if backup.resolve() != backup:
                        raise ValueError("Unexpected symlink at the MaciPEAK backup directory.")
                    label = file.parent.name + "-" + file.name
                    target = backup / (label + "." + hashlib.sha256(old[file]).hexdigest()[:12])
                    if not target.exists():
                        with target.open("xb") as handle:
                            os.fchmod(handle.fileno(), 0o600)
                            handle.write(old[file])
                replace(file, data)
                applied.append(file)
        except BaseException:
            for file in reversed(applied):
                replace(file, old[file])
            raise
    finally:
        os.close(fd)
    print(("Removed MaciPEAK registration for " if remove else "Registered Steam PEAK at ") + str(app))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["path", "inspect", "register", "unregister"])
    parser.add_argument("--steam-library", metavar="DIR")
    parser.add_argument("--expected-arch", choices=ARCHITECTURES)
    parser.add_argument("--steam-root", type=Path, default=Path.home() / "Library/Application Support/Steam")
    args = parser.parse_args()
    if args.expected_arch and args.action not in ("inspect", "register"):
        parser.error("--expected-arch requires inspect or register")
    steam = args.steam_root.expanduser().resolve()
    files = library_files(steam)
    if args.action in ("path", "inspect"):
        folder = choose_library(steam, args.steam_library, files[0].read_bytes())
        app = folder / "steamapps/common/PEAK/PEAK.app"
        if args.action == "inspect":
            installed_architectures(app, args.expected_arch)
        print(app)
    else:
        register(steam, args.steam_library, files, args.action == "unregister", args.expected_arch)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, IndexError, struct.error) as error:
        sys.exit("MaciPEAK Steam integration: %s" % error)
