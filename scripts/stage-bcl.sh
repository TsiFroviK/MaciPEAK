#!/bin/sh
# stage-bcl.sh WINDOWS_GAME STAGED_APP auto|UNITY_APP|MONO_TREE|UNITY_EDITOR_PKG
set -eu
fail() { printf 'stage-bcl: %s\n' "$*" >&2; exit 1; }
[ "$#" -eq 3 ] || fail 'usage: stage-bcl.sh WINDOWS_GAME STAGED_APP auto|UNITY_APP|MONO_TREE|UNITY_EDITOR_PKG'
src=$(cd "$1/PEAK_Data/Managed" && pwd -P)
dest=$(cd "$2/Contents/Resources/Data/Managed" && pwd -P)
[ "$src" != "$dest" ] || fail 'the staging directory must be separate from the game input'
here=$(cd "$(dirname "$0")" && pwd -P)
manifest="$here/bcl-6000.3.15f1.sha256"
source=$3
version=6000.3.15f1
tree=Resources/Scripting/MonoBleedingEdge/lib/mono
profile=unityjit-macos

if [ "$source" = auto ]; then
    installed="/Applications/Unity/Hub/Editor/$version/Unity.app"
    if [ -f "$installed/Contents/$tree/$profile/mscorlib.dll" ]; then source=$installed; fi
fi
if [ "$source" = auto ]; then
    cache=${MACIPEAK_CACHE:-"$(dirname "$2")/cache"}
    source=$("${PEAK_BUILD_PYTHON:-python3}" "$here/unity-mono-profile.py" "$cache" "$manifest")
elif [ -f "$source" ]; then
    app=$(cd "$2" && pwd -P)
    work=$(mktemp -d "$(dirname "$app")/.peak-bcl.XXXXXXXX")
    trap 'rm -rf "$work"' EXIT
    trap 'exit 1' HUP INT TERM
    # The XAR contains a gzip-compressed cpio stream. Extract the single
    # profile tree. Verify individual libraries with the Editor's signed file hashes below.
    member="./Unity/Unity.app/Contents/$tree/$profile"
    "${PEAK_BUILD_PYTHON:-python3}" "$here/xar-member.py" "$source" Unity.pkg.tmp/Payload | tar -xf - -C "$work" "$member"
    source="$work/$member"
fi
root=
for dir in "$source" "$source/$profile" "$source/lib/mono/$profile" \
        "$source/Contents/$tree/$profile" "$source/Unity.app/Contents/$tree/$profile" \
        "$source/Unity/Unity.app/Contents/$tree/$profile" \
        "$source/Editor/Data/MonoBleedingEdge/lib/mono/$profile" "$source/Data/MonoBleedingEdge/lib/mono/$profile"; do
    if [ -f "$dir/mscorlib.dll" ]; then root=$dir; break; fi
done
[ -n "$root" ] || fail "expected a Unity $version Editor, its $profile profile tree, or the official Mac Editor .pkg"
verify() {
    [ -f "$1" ] || fail "missing assembly: $1"
    digest=$(shasum -a 256 < "$1")
    [ "${digest%% *}" = "$2" ] || fail "unexpected BCL assembly: $1 (expected $2)"
}
# Each manifest row is the profile-relative filename and its Windows/macOS
# SHA-256 in Unity's signed 6000.3.15f1 CodeResources. PEAK uses unityjit-win32.
# Check the entire source and destination set before replacing any file.
count=0
while read -r relative win_hash mac_hash; do
    verify "$src/${relative##*/}" "$win_hash"
    verify "$root/$relative" "$mac_hash"
    count=$((count + 1))
done < "$manifest"
[ "$count" -eq 30 ] || fail 'incomplete PEAK BCL manifest'
while read -r relative win_hash mac_hash; do
    cp "$root/$relative" "$dest/${relative##*/}"
done < "$manifest"
printf 'Staged %s verified Unity %s macOS Mono assemblies, including profile facades.\n' "$count" "$version"
